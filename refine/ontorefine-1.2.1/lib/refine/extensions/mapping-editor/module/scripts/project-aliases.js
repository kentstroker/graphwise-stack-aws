/**
 * 'theProject' is an object initialized when the application is loaded and it is a global variable.
 * When working in the context of a project, it is always loaded with the current data of the project.
 */

ProjectAliasesUIExtension = {};

/**
 * Initializes the components and the functionality related to the project aliases.
 */
ProjectAliasesUIExtension.init = function () {
  var aliasesData = ProjectAliasesUIExtension._loadAliases();

  $(document).ready(function () {
    var container = $("#header #project-title");

    ProjectAliasesUIExtension._addIdentifierElements(container);

    ProjectAliasesUIExtension._addAliasesElements("aliasesInput", container);
    ProjectAliasesUIExtension._initSelectComponent("aliasesInput", aliasesData);
  });
}

ProjectAliasesUIExtension._addIdentifierElements = function (container) {
  var identifierElements = `
    <div id="project-identifier-container">
      <label class="identifier-label" for="projectIdentifier">Project ID:</label>
      <div id="projectIdentifier">${theProject.id}</div>
    </div>
  `;

  $(identifierElements).appendTo(container);
}

ProjectAliasesUIExtension._addAliasesElements = function (selectElemId, container) {
  var aliasesElements = `
    <div id="project-aliases-container">
      <label class="aliases-label" for="${selectElemId}">Aliases:</label>
      <select id="${selectElemId}" class="aliases-select" multiple="multiple"></select>
    </div>
  `;

  $(aliasesElements).appendTo(container);
}

/**
 * Initializes the select functionalities for the aliases component. The method will apply
 * the select2 functions to the HTML element, attach specific events with handlers. The events
 * will handle what should happen when a new tag (alias) is added or old one is removed.
 * 
 * @param {string} selectElemId the identifier of the select HTML element
 * @param {array} aliasesData the initial data that will be populated in the select.
 *                            Basically the current aliases, if there are any
 */
ProjectAliasesUIExtension._initSelectComponent = function (selectElemId, aliasesData) {
  var aliasesInput = $(`#${selectElemId}`);

  // attaches select functionality
  aliasesInput.select2({
    data: aliasesData,
    tags: true,
    tokenSeparators: [","],
    maximumInputLength: 16
  });

  // attaches event handling on new tag creation
  aliasesInput.on("select2:select", function (event) {
    var addedValue = event.params.data.text;
    var data = {
      project: theProject.id,
      added: [addedValue]
    }

    // this event cannot be prevented, the tag is rendered even if there was an error
    // so we need to manually remove them from the DOM.
    // The alternative is to use different events, but there are other issues with them
    var isSuccessful = ProjectAliasesUIExtension._save(data);
    if (isSuccessful) {
      return;
    }

    // sometimes this does not work properly
    var foundElement = aliasesInput.find(`option[value='${addedValue}']`);
    if (foundElement && foundElement.length) {
      foundElement.remove();
      ProjectAliasesUIExtension._updateAliasesData(aliasesData, addedValue);
    } else {

      // so as last resort we do Papa Roach
      aliasesInput.find('option').each(function () {
        var optElem = $(this);
        if (optElem.text() === addedValue
          || optElem.innerText === addedValue
          || JSON.stringify(optElem.text()) === addedValue) {
          optElem.remove();
          ProjectAliasesUIExtension._updateAliasesData(aliasesData, addedValue);
        }
      });
    }
  });

  // attaches event handling on tag removal
  aliasesInput.on("select2:unselect", function (event) {
    var data = {
      project: theProject.id,
      removed: [event.params.data.text]
    }

    ProjectAliasesUIExtension._save(data);
  });
}

/**
 * Modifies the provided data array by filtering the given value from it, if it exists.
 * 
 * @param {Array} data to be updated
 */
ProjectAliasesUIExtension._updateAliasesData = function (data, valueToFilter) {
  data = data.filter(function (aliasValue) {
    return aliasValue !== valueToFilter;
  });
}

/**
 * Loads the current project aliases via request to the server.
 * 
 * @returns array of the current project aliases, if there are any
 */
ProjectAliasesUIExtension._loadAliases = function () {
  var aliases = [];
  jQuery.ajax({
    type: "GET",
    url: window.location.origin + "/project-aliases?" + $.param({ "project": theProject.id }),
    async: false,
    dataType: "json",
    success: function (result) {
      // remaps the result array in data format that suits the select2 princess
      result.forEach((item, index) => aliases.push({ id: index, text: item, selected: true }));
    },
  });

  return aliases;
}

/**
 * Executes an save request for the project aliases. The input data may contain information about
 * added and/or removed aliases.
 * 
 * @param {object} data containing information about added or removed aliases
 * @returns object representing an option for the select2 that will be used to render the added
 *          value into the component. When there is an error, <code>null</code> is returned, which
 *          prevent the visualization of the value
 */
ProjectAliasesUIExtension._save = function (data) {
  var successful = true;
  $.post({
    url: window.location.origin + "/project-aliases",
    data: JSON.stringify(data),
    contentType: "application/json",
    async: false
  }).done(function () {
    ProjectAliasesUIExtension._refreshProjectMetadata();
  }).fail(function (error) {
    var msg = error?.responseJSON?.message;
    if (!msg) {
      msg = "There was an error. Check the browser console for more details.";
    }

    ProjectAliasesUIExtension._showError(msg);
    console.log(JSON.stringify(error));
    successful = false;
  });

  return successful;
}

/**
 * Refreshes the project metadata by requesting fresh data from the server.
 */
ProjectAliasesUIExtension._refreshProjectMetadata = function () {
  $.getJSON({
    url: "command/core/get-project-metadata?" + $.param({ project: theProject.id }),
    async: false
  }).done(function (freshMetadata) {
    theProject.metadata = freshMetadata;
  }).fail(function () {
    ProjectAliasesUIExtension._showError(
      "Failed to synchronize project model.\nRefresh the page to see all the changes.");
  });
}

/**
 * Pushes toast notification of error type with the provided message.
 * 
 * @param {string} message to be shown in the toast 
 */
ProjectAliasesUIExtension._showError = function(message) {
  $.toast({
    heading: 'Error',
    text: message,
    showHideTransition: 'fade',
    icon: 'error',
    position: 'bottom-right',
    allowToastClose: true,
    hideAfter: 10000
  });
}
