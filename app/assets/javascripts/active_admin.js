//= require active_admin/base

/* Used on the workspace#edit and finalizations#edit pages */
function attemptTriggerEnumChangeAndSave(selectSelector, option) {
  const select = document.querySelector(selectSelector);
  if (select) {
    select.value = option;
    const submit = document.querySelector(".action.input_action input");
    if (submit) submit.click();
  }
}
