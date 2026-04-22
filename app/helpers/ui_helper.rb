module UiHelper
  STATUS_COLORS = {
    "open"             => "bg-slate-100 text-slate-700 border-slate-200",
    "in_progress"      => "bg-amber-50 text-amber-800 border-amber-200",
    "implemented"      => "bg-sky-50 text-sky-800 border-sky-200",
    "ready_for_test"   => "bg-indigo-50 text-indigo-800 border-indigo-200",
    "testing"          => "bg-violet-50 text-violet-800 border-violet-200",
    "done"             => "bg-emerald-50 text-emerald-800 border-emerald-200",
    "blocked"          => "bg-rose-50 text-rose-800 border-rose-200",
    "draft"            => "bg-slate-100 text-slate-700 border-slate-200",
    "active"           => "bg-sky-50 text-sky-800 border-sky-200",
    "archived"         => "bg-slate-100 text-slate-500 border-slate-200",
    "running"          => "bg-amber-50 text-amber-800 border-amber-200",
    "passed"           => "bg-emerald-50 text-emerald-800 border-emerald-200",
    "failed"           => "bg-rose-50 text-rose-800 border-rose-200",
    "partial"          => "bg-amber-50 text-amber-800 border-amber-200",
    "aborted"          => "bg-slate-200 text-slate-700 border-slate-300",
    "pending"          => "bg-slate-100 text-slate-600 border-slate-200",
    "pass"             => "bg-emerald-50 text-emerald-800 border-emerald-200",
    "fail"             => "bg-rose-50 text-rose-800 border-rose-200",
    "skipped"          => "bg-slate-100 text-slate-500 border-slate-200",
    "resolved"         => "bg-emerald-50 text-emerald-800 border-emerald-200",
    "wontfix"          => "bg-slate-200 text-slate-700 border-slate-300"
  }.freeze

  SEVERITY_COLORS = {
    "low"      => "bg-slate-100 text-slate-600 border-slate-200",
    "medium"   => "bg-sky-50 text-sky-800 border-sky-200",
    "high"     => "bg-amber-50 text-amber-800 border-amber-200",
    "critical" => "bg-rose-50 text-rose-800 border-rose-200"
  }.freeze

  def status_pill(value)
    klass = STATUS_COLORS[value.to_s] || "bg-slate-100 text-slate-700 border-slate-200"
    content_tag :span, value.to_s.gsub("_", " "),
      class: "inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-medium #{klass}"
  end

  def severity_pill(value)
    klass = SEVERITY_COLORS[value.to_s] || "bg-slate-100 text-slate-600 border-slate-200"
    content_tag :span, value.to_s,
      class: "inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-medium #{klass}"
  end

  def card(title: nil, &block)
    content_tag :section, class: "rounded-xl border border-slate-200 bg-white shadow-sm" do
      (title ? content_tag(:header, title, class: "px-4 py-3 border-b border-slate-100 text-sm font-semibold text-slate-700") : "".html_safe) +
        content_tag(:div, capture(&block), class: "p-4")
    end
  end

  def progress_bar(percent, passed: 0, failed: 0, total: 0)
    percent = percent.to_f
    content_tag :div, class: "w-full h-2 rounded-full bg-slate-100 overflow-hidden" do
      content_tag :div, "", class: "h-full #{failed.to_i.positive? ? 'bg-rose-500' : 'bg-emerald-500'}",
        style: "width: #{[percent, 100].min}%"
    end
  end

  def format_time(t)
    return "—" if t.blank?
    t.strftime("%b %-d, %Y %H:%M")
  end
end
