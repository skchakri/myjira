module DocumentsHelper
  KIND_PILL = { "plan" => "pill-accent", "spec" => "pill-block", "report" => "pill-pass", "note" => "pill-quiet" }.freeze

  def document_kind_pill(kind)
    content_tag(:span, kind, class: "pill #{KIND_PILL.fetch(kind.to_s, 'pill-quiet')}")
  end
end
