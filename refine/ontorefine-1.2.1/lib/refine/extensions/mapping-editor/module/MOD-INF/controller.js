importPackage(com.ontotext.mapping.commands);

var theProject = {};
var html = "text/html";
var encoding = "UTF-8";
var ClientSideResourceManager = Packages.com.google.refine.ClientSideResourceManager;

function init() {

  var RefineServlet = Packages.com.google.refine.RefineServlet;
  RefineServlet.cacheClass(Packages.com.ontotext.mapping.operations.SaveMappingOperation$RDFMappingChange);

  /*
   *  Attach the MappingDefinitionOverlay to each project.
   */
  Packages.com.google.refine.model.Project.registerOverlayModel(
    "mappingDefinition",
    Packages.com.ontotext.mapping.MappingDefinitionOverlay);

  /*
  * Register save mapping command and operations
  */
  Packages.com.google.refine.operations.OperationRegistry.registerOperation(
    module, "save-rdf-mapping", Packages.com.ontotext.mapping.operations.SaveMappingOperation);
  RefineServlet.registerCommand(module, "save-rdf-mapping", new SaveMappingCommand());

  // Inject script/styles
  ClientSideResourceManager.addPaths(
    "project/scripts",
    module,
    [
      "scripts/mapping-extension.js",

      // aliases libs and scripts
      "scripts/libs/select2/select2.min.js",
      "scripts/libs/toast/jquery.toast.min.js",
      "scripts/project-aliases.js"
    ]
  );

  // Style files to inject into /project page
  ClientSideResourceManager.addPaths(
    "project/styles",
    module,
    [
      "styles/mapping-extension.less",

      // aliases libs and styles
      "styles/libs/select2/select2.min.css",
      "styles/libs/toast/jquery.toast.min.css",
      "styles/project/aliases.less"
    ]
  );

  // TOOD: we could add another module which does only the re-skinning of OpenRefine

  // Overrides the default theme of OpenRefine with our own
  ClientSideResourceManager.addPaths(
    "index/styles",
    module,
    [
      "styles/remove-openrefine-logos.less",
      "styles/onto-theme.less",
      "styles/index/onto-create-project.less",
      "styles/index/onto-open-project.less",
      "styles/index/onto-importing-wizard.less"
    ]
  );

  ClientSideResourceManager.addPaths(
    "project/styles",
    module,
    [
      "styles/remove-openrefine-logos.less",
      "styles/onto-theme.less",
      "styles/project/onto-project.less",
      "styles/project/onto-data-table-view.less",
    ]
  );

  ClientSideResourceManager.addPaths(
    "preferences/styles",
    module,
    [
      "styles/preferences/onto-preferences.less"
    ]
  );
}

function process(path, request, response) {
  if (path == "/" || path == "") {
    var context = {};
    send(request, response, "index.html", context);
  }
}

function send(request, response, template, context) {
  butterfly.sendTextFromTemplate(request, response, context, template, encoding, html);
}
