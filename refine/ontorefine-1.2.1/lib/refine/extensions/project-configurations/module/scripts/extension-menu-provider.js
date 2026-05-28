/**
 * Inits the language translations for the different labels of the extension.
 */
I18NUtil.init("project-configurations");

/**
 * Adds the button for opening of the dialog in the export menu.
 */
$(function () {

  // adds divider
  ExporterManager.MenuItems.push({});

  ExporterManager.MenuItems.push({
    id: "project-configurations/export",
    label: $.i18n("project-configurations-extension/menu-label"),
    click: function () {
      // TODO: Is it possible to have some kind of memory leak here?
      // The invocation seems kinda odd.
      new ExportProjectConfigurationsDialog().launch();
    }
  });
});
