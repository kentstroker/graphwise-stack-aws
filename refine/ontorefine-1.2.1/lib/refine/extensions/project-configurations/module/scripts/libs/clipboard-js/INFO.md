# Clipboard-JS Information

Clipboard-JS is used in the export project configuration dialog, in particular the Copy button.

The library is used directly, instead of dependency or definition in `<script>` tag, because we
don't want to depend on the Internet connection in order for the extension to work properly.
This allows the Refine to work in a offline mode.

The resources of the library are injected in the `controller.js`, when all scripts for the module
are registered.

The current version of the resources is retrieved from the `master` branch of the [clipboard-js](https://github.com/zenorocha/clipboard.js).

`package.json` version: `2.0.11`
