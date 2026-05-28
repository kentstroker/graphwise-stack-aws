var project;
var level;
var clipboard;

function ExportProjectConfigurationsDialog() {
  // Mysterious are the scopes in the JavaScript World...
  // 'theProject' is defined in <script> tag in 'project.vt' and after that populated in
  // 'project.js' in the main OpenRefine web module.
  // All extensions, which register resources in the 'project' module, have access to it.
  // Don't ask.
  this.project = theProject;
}

/**
 * Executes HTTP request to the 'project-configs' command. The result is used to initialize the
 * dialog that will be shown to the user.
 */
ExportProjectConfigurationsDialog.prototype.launch = function () {
  var _self = this;
  $.getJSON(
    "command/project-configurations/export?" + $.param({ project: this.project.id }),
    null,
    function (projectConfigs) {
      _self._showExportConfigurationDialog(projectConfigs);
    },
    "jsonp"
  );
};

/**
 * Initializes the dialog and the components in it. Handles the translation of the labels, buttons
 * click handling and the actual displaying of the dialog window.
 * 
 * @param {object} projectConfigs the JSON document representing the project configurations
 */
ExportProjectConfigurationsDialog.prototype._showExportConfigurationDialog = function (projectConfigs) {
  var frame = $(DOM.loadHTML("project-configurations", "scripts/export-project-configurations-dialog.html"));
  var dialogElements = DOM.bind(frame);

  dialogElements.dialogHeader.html($.i18n("project-configurations-extension/dialog-header"));

  // set the configuration JSON into the textarea
  dialogElements.textarea.text(JSON.stringify(projectConfigs, null, 2));

  this._initCopyButton(dialogElements);
  this._initCloseButton(dialogElements);
  this._initDownloadButton(dialogElements, theProject.id);

  this.level = DialogSystem.showDialog(frame);
};

/**
 * Translates and bind on click handler on the copy button.
 * 
 * @param {object} dialogElements contains the elements of the project configurations dialog
 */
ExportProjectConfigurationsDialog.prototype._initCopyButton = function (dialogElements) {
  dialogElements.copyButton.html($.i18n("project-configurations-extension/copy"));

  var copyBtnElement = dialogElements.copyButton[0];
  ButtonsTooltip.attachClearEvents(copyBtnElement);

  this.clipboard = new ClipboardJS(copyBtnElement);

  this.clipboard.on('success', function (event) {
    event.clearSelection();
    ButtonsTooltip.showTooltip(event.trigger, $.i18n("project-configurations-extension/copied"));
  });

  this.clipboard.on("error", function (event) {
    ButtonsTooltip.showTooltip(event.trigger, ButtonsTooltip.fallbackMessage(event.action));
  });
}

/**
 * Translates and bind on click handler on the close button.
 * 
 * @param {object} dialogElements contains the elements of the project configurations dialog
 */
ExportProjectConfigurationsDialog.prototype._initCloseButton = function (dialogElements) {
  var _self = this;
  var closeBtn = dialogElements.closeButton;

  closeBtn.html($.i18n("core-buttons/close"));

  closeBtn.on('click', function () {
    DialogSystem.dismissUntil(_self.level - 1);
    _self.clipboard.destroy();
  });
};

/**
 * Translates and binds on click handler for the download button.
 * 
 * @param {object} dialogElements contains the elements of the project configurations dialog
 * @param {string} projectIdentifier the identifier of the current project. Used for filename generation
 */
ExportProjectConfigurationsDialog.prototype._initDownloadButton = function (dialogElements, projectIdentifier) {
  var downloadBtn = dialogElements.downloadButton;

  downloadBtn.html($.i18n("project-configurations-extension/download"));

  downloadBtn.on("click", function () {
    var json = dialogElements.textarea[0].value;
    var filename = projectIdentifier + "-project-configurations.json";

    var element = document.createElement("a");
    element.setAttribute("href", "data:text/plain;charset=utf-8," + encodeURIComponent(json));
    element.setAttribute("download", filename);

    element.style.display = "none";
    document.body.appendChild(element);

    element.click();
    document.body.removeChild(element);
  });
};
