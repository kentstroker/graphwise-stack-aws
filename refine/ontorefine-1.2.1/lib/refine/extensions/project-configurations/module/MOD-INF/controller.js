importPackage(com.ontotext.refine.extensions.pc.commands);

var VERSION = "1.0";

var LOGGER = Packages.org.slf4j.LoggerFactory.getLogger("project-configs-extension");

var CSRM = Packages.com.google.refine.ClientSideResourceManager;
var RS = Packages.com.google.refine.RefineServlet;

/*
 * Function invoked to initialize the extension.
 */
function init() {
  LOGGER.info("Initializing Refine Project Configurations Extension...");

  this._registerResources();

  LOGGER.info("Initialization of Project Configurations Extension is done.");
}

/**
 * Registers the web resources for the extension. The method will register all commands, JavaScript
 * and style (less or CSS) files.
 */
function _registerResources() {
  LOGGER.trace("Registering Project Configurations Extension commands.");
  this._registerCommands();

  LOGGER.trace("Registering Project Configurations Extension scripts.");
  this._registerScripts();

  LOGGER.trace("Registering Project Configurations Extension styles.");
  this._registerStyles();
}

function _registerCommands() {
  // registers Export Project command (basically callback for the backend logic)
  RS.registerCommand(module, "export", new ExportProjectConfigurationsCommand());
}

function _registerScripts() {
  CSRM.addPaths(
    "project/scripts",
    module,
    [
      "scripts/libs/clipboard-js/clipboard.min.js",
      "scripts/utils/i18n.js",
      "scripts/buttons-tooltip.js",
      "scripts/extension-menu-provider.js",
      "scripts/export-project-configurations-dialog.js"
    ]
  );
}

function _registerStyles() {
  CSRM.addPaths(
    "project/styles",
    module,
    [
      "styles/libs/primer-tooltips.css",
      "styles/project-configurations.less"
    ]
  );
}

// TODO: not sure it is required
function process(path, request, response) {
  if (path == "/" || path == "") {
    var context = {};
    context.version = VERSION;
    send(request, response, "index.vt", context);
  }
}

// TODO: not sure it is required
function send(request, response, template, context) {
  butterfly.sendTextFromTemplate(request, response, context, template, "UTF-8", "text/html");
}
