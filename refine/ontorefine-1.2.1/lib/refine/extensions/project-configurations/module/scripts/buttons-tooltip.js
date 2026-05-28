/**
 * Contains logic for adding, displaying and clearing of tooltips from a buttons.
 */
var ButtonsTooltip = {};

/**
 * Attaches events on the element, which will clear the tooltip on specific conditions.<br>
 * Currently the tooltip will be cleared on:<br>
 * 1. mouseleave<br>
 * 
 * @param {HTMLElement} element to which to attach the events
 */
ButtonsTooltip.attachClearEvents = function (element) {
  element.addEventListener('mouseleave', ButtonsTooltip.clearTooltip);
}

/**
 * Clears the tooltip of the target element of the input event.
 * 
 * @param {MouseEvent} event which triggered the clearing of the tooltip
 */
ButtonsTooltip.clearTooltip = function (event) {
  event.currentTarget.classList.remove("tooltipped", "tooltipped-s");
  event.currentTarget.removeAttribute('aria-label');
}

/**
 * Shows tooltip with specific message.
 * 
 * @param {HTMLElement} element to which to attach the tooltip
 * @param {string} msg message to show in the tooltip
 */
ButtonsTooltip.showTooltip = function (element, msg) {
  element.classList.add("tooltipped", "tooltipped-s");
  element.setAttribute('aria-label', msg);
}

/**
 * Generates fallback message for copy functionality, when the standard mechanism aren't allowed.
 * The message will notify the user that the operation was not successful and (s)he should do manual
 * coping or cutting of the desired data.<br>
 * The message could be used as message in the tooltips.
 *  
 * @param {*} action that was performed. Values 'X' for cut, 'C' for copy
 * @returns the generated fallback message
 */
ButtonsTooltip.fallbackMessage = function (action) {
  if (/iPhone|iPad/i.test(navigator.userAgent)) {
    return $.i18n("project-configurations-extension/no-support");
  }

  var translatedPress = $.i18n("project-configurations-extension/press");
  var actionKey = (action === "cut" ? "X" : "C");
  var translatedTo = $.i18n("project-configurations-extension/to-with-spaces");
  if (/Mac/i.test(navigator.userAgent)) {
    return translatedPress + " ⌘-" + actionKey + translatedTo + action;
  }

  return translatedPress + " Ctrl-" + actionKey + translatedTo + action;
}
