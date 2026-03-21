class JsonEditorInput < Formtastic::Inputs::TextInput
  def to_html
    template.content_tag(:li, style: "height: 650px;", class: "json_editor input") do
      builder.hidden_field(method, value: object.public_send(method)&.to_json)
    end
  end
end