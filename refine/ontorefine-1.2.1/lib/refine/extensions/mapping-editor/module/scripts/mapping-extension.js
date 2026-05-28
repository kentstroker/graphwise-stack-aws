
function RdfMappingDialog(project) {
  this._init(project);
};

RdfMappingDialog.prototype._init = function (project) {
  window.addEventListener("message", isFormPristine);
  var self = this;
  var dialog = $(DOM.loadHTML("mapping-editor", "iframe.html"));
  var isPristine = true;
  var isEditorPristine = true;
  dialog.find("#rdfMappingFrame").attr('src', "extension/mapping-editor/?dataProviderID=ontorefine:" + project.id);
  dialog.find("#cancelButton").click(function () {
    if (isPristine && isEditorPristine) {
      exit();
    } else {
      confirmExit();
    }
  });

  // TODO: i18n
  var projectInfo = dialog.find(".project-info");
  projectInfo.append(`<label class="info-name-label" for="infoName">Name:</label>`);
  projectInfo.append(`<div id="infoName">${project.metadata.name}</div>`);

  projectInfo.append(`<label class="info-identifier-label" for="infoIdentifier">Identifier:</label>`);
  projectInfo.append(`<div id="infoIdentifier">${project.id}</div>`);

  if (project.metadata.customMetadata && project.metadata.customMetadata.aliases) {
    projectInfo.append(`<label class="info-aliases-label" for="infoAliases">Aliases:</label>`);
    projectInfo.append(`<div id="infoAliases">${project.metadata.customMetadata.aliases.join(", ")}</div>`);
  }

  self._level = DialogSystem.showDialog(dialog);
  dialog.parent(".dialog-container")
    .addClass("dialog-container-mapping")
    .draggable("destroy");

  function confirmExit() {
    if (confirm("There are unsaved changes! Are you sure, you want to exit?")) {
      exit();
    }
  }

  function exit() {
    window.removeEventListener("message", isFormPristine);
    ui.historyPanel.update();
    DialogSystem.dismissUntil(self._level - 1);
  }

  function isFormPristine(e) {
    var msg = e.data;
    if (msg.startsWith('editor')) {
      isEditorPristine = msg === 'editorPristine';
    } else {
      isPristine = msg === 'pristine';
    }
    window.parent.postMessage(msg, '*');
  }
};

// extend the column header menu
$(function () {

  ExtensionBar.MenuItems.push(
    {
      "id": "rdf-mapping",
      "label": "RDF Mapping",
      "submenu": [
        {
          "id": "rdf/edit-rdf-mapping",
          label: "Edit RDF Mapping",
          click: function () { new RdfMappingDialog(theProject); }
        },
      ]
    }
  );

  // this is probably code for another extension, but we've done it here...
  // Initializes the project aliases functionalities, components, etc.
  ProjectAliasesUIExtension.init();
});

