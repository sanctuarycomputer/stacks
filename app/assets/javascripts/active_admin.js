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

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll(".json_editor.input").forEach((el) => {
    const input = el.querySelector('input');
    const data = input.value;

    const editor = new JSONEditor(el, {
      mode: "code",
      modes: ["tree", "code"],
      mainMenuBar: false,
      navigationBar: false,
      statusBar: false,
      onChange: () => {
        try {
          input.value = editor.getText();
        } catch (e) {}
      }
    });

    // Set initial value
      try {
        const initial = JSON.parse(data || "{}");
        editor.set(initial);
    } catch (e) {
      editor.set({});
    }
  });
});