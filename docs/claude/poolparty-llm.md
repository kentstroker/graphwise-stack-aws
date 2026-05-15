# PoolParty 10.2 pluggable LLM wiring (Build Your Taxonomy)

Detail backing the PoolParty LLM rule in `CLAUDE.md`.

PoolParty 10.2+ exposes a pluggable LLM via system properties
(`poolparty.llm.api`, `poolparty.llm.model`, `poolparty.llm.bedrock.region`)
plus the AWS SDK default credential chain. The chart wires it as four
moving pieces:

1. **`charts/poolparty/values.yaml::llm.*`** holds the model/region/Secret-name
   defaults. Default model: `us.meta.llama3-3-70b-instruct-v1:0`
   (a system-defined cross-region inference profile that routes
   Llama 3.3 70B Instruct across `us-east-1`/`us-east-2`/`us-west-2`).
   Default region: `us-west-2`. Gate: `llm.enabled` (default `true`
   when overridden via the umbrella; default `false` if the poolparty
   subchart is installed standalone). **Two-layer override footgun:**
   `poolparty.llm.model` is duplicated in `charts/graphwise-stack/values.yaml`
   (umbrella) and the umbrella's value wins. Edits to one without the
   other have no effect at deploy time. Grep `claude\|llama\|nova` across
   `charts/` before any LLM-config change.
2. **`charts/poolparty/templates/deployment.yaml`** adds the four
   `POOLPARTY_LLM_*` env vars + `AWS_REGION` / `AWS_ACCESS_KEY_ID` /
   `AWS_SECRET_ACCESS_KEY` (the latter two via `secretKeyRef` from the
   Secret named in `llm.awsCredentialsSecret`), all gated on
   `.Values.llm.enabled`.
3. **`charts/graphwise-stack/templates/poolparty-aws-credentials.yaml`**
   materializes the AWS-creds Secret in the `graphwise` namespace
   (where PoolParty lives), sourced from the SAME overlay block
   (`graphrag-secrets.awsCredentials` in `~/graphwise-secrets.yaml`)
   that already feeds the `graphrag-components-aws-credentials` Secret
   in the `graphrag` namespace. **Same overlay, two materializations**,
   one in each namespace. Pods can only mount Secrets from their own
   namespace, so cross-namespace mounting isn't an option; reflector
   is overkill for a two-namespace fan-out. The duplication is
   intentional and obvious.
4. **SMC Taxonomy Advisor instance** (operator step, NOT chart-side):
   after deploy, the operator logs into PoolParty's SMC, expands
   External Services → Taxonomy Advisor, and creates an instance
   with an API key issued by Graphwise. This API key authenticates
   the *feature*, separate from the AWS Bedrock creds which authorize
   the *model invocation*. Without it, "Build Your Taxonomy" still
   reports "no LLM configured" even though the backend is wired.
   Documented in QUICKSTART "Optional: Activate Build Your Taxonomy"
   + CONSOLE-GUIDE → PoolParty Thesaurus.

## IAM scope

`bedrock:InvokeModel` on the Llama foundation-model ARN in every
region the cross-region inference profile routes to, PLUS the
inference-profile ARN itself, alongside the Cohere embed ARN already
in the policy. The inline policy at SETUP §4b uses a Resource array
with:
`arn:aws:bedrock:us-west-2::foundation-model/cohere.embed-english-v3`,
`arn:aws:bedrock:us-east-1::foundation-model/meta.llama3-3-70b-instruct-v1:0`,
`arn:aws:bedrock:us-east-2::foundation-model/meta.llama3-3-70b-instruct-v1:0`,
`arn:aws:bedrock:us-west-2::foundation-model/meta.llama3-3-70b-instruct-v1:0`,
and `arn:aws:bedrock:us-west-2:<account-id>:inference-profile/us.meta.llama3-3-70b-instruct-v1:0`
(the inference-profile ARN is account-scoped — note the account-id
segment). The bare foundation-model ARN alone is insufficient: when
the call routes via the profile, Bedrock authorizes against BOTH the
profile ARN AND whichever region the call lands in, so all three
regions appear.

## Inference profile requirement

Newer Bedrock chat models (Llama 3.3+, Claude Sonnet 3.5 v2 onward,
Nova Pro/Lite, Mistral Large 2) **cannot be invoked on-demand by
their foundation-model ID** — Bedrock returns
`InvalidRequestException: Invocation of model ID X with on-demand
throughput isn't supported. Retry your request with the ID or ARN of
an inference profile that contains this model.` The fix is to use
the system-defined cross-region inference profile ID, which is the
foundation model ID with a region prefix (`us.` for US, `eu.` for
EU, `apac.` for APAC). Burned a deploy on this 2026-05-14; symptom
is the InvalidRequestException above.

## Anthropic Claude use-case form (separate gate)

AWS retired the old "Modify model access" approval flow for ALL
providers (Llama, Amazon Nova, Mistral, Cohere — IAM is now the
only gate). Anthropic Claude models are the exception: invoking
them requires a one-time **use-case details form** in the Bedrock
Console (Model access → Anthropic → fill form → submit, ~5-15 min
approval). Symptom if you forget: `ResourceNotFoundException: Model
use case details have not been submitted for this account.` We
default to Llama specifically to avoid this gate; Claude is a
one-form-away swap if you prefer its quality.

## JAR set proves it works

The `quay.io/ontotext/poolparty:10.2.0` image ships
`langchain4j-bedrock-1.12.2.jar` + `bedrockruntime-2.41.34.jar` in
`/usr/share/poolparty/lib/common/`, so no proxy (LiteLLM / Bedrock
Access Gateway) is needed. Direct SDK calls. langchain4j accepts
inference-profile IDs in `modelId` unchanged from foundation-model
IDs.

## Secret-only updates require a manual rollout-restart

AWS credentials reach the pod via env vars sourced from the Secret
`poolparty-aws-credentials` (and similarly for graphrag-components).
K8s snapshots `secretKeyRef` values at pod-start time. When a
`helm upgrade` only changes the Secret's contents (e.g., the
operator filled in `~/graphwise-secrets.yaml` and re-ran helm),
the Deployment spec is unchanged, no rollout fires, and the running
pod keeps the old (often empty) env values — so the AWS SDK falls
through to IMDS and uses the EC2 instance role, which lacks
`bedrock:InvokeModel`, surfacing as `AccessDeniedException` against
the `arn:aws:sts::...:assumed-role/graphwise-stack-<sub>-ec2-role/...`
principal. Force-roll the pod after such an upgrade:
`kubectl -n graphwise rollout restart deploy/graphwise-stack-poolparty`.
Proper structural fix (deferred): add a `checksum/aws-creds`
annotation to `charts/poolparty/templates/deployment.yaml` so any
Secret change auto-rolls.

## Symptom-to-cause

"no LLM configured" in the PoolParty UI after a clean deploy almost
always means the SMC step (4) wasn't done. If the SMC step IS done
and the error persists, walk the layers:

1. `kubectl exec ... -- env | grep POOLPARTY_LLM` — if empty, the
   `poolparty.llm.enabled` value didn't take effect (stale umbrella
   values overlay). If model ID shows the bare foundation-model ID
   (no `us.` prefix), the chart edit didn't land in both layers
   (subchart + umbrella).
2. `kubectl exec ... -- printenv AWS_ACCESS_KEY_ID | head -c 4` —
   should print `AKIA`. Blank means the Secret was rendered without
   the `-f ~/graphwise-secrets.yaml` overlay (helm upgrade needs all
   THREE -f flags: base + per-deploy + secrets; reset-helm.sh adds
   the secrets flag automatically) OR the pod is stale from before
   the secrets-overlay upgrade (rollout-restart per above).
3. `kubectl logs ... | grep -iE 'bedrock|inference|accessdenied|resourcenot'`
   — `AccessDeniedException` against an inference-profile ARN means
   the IAM policy needs the profile ARN added; `AccessDeniedException`
   against an `assumed-role/...-ec2-role` principal means the SDK
   fell through to IMDS (env vars empty/missing — see step 2);
   `ResourceNotFoundException ... use case details` means Anthropic
   model + missing the use-case form.
