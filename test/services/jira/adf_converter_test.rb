require "test_helper"

class Jira::AdfConverterTest < ActiveSupport::TestCase
  def conv(node) = Jira::AdfConverter.to_markdown(node)

  test "nil and empty become empty string" do
    assert_equal "", conv(nil)
    assert_equal "", conv({})
  end

  test "paragraph with text" do
    doc = { "type" => "doc", "content" => [
      { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello world" }] }
    ] }
    assert_equal "Hello world", conv(doc)
  end

  test "marks: strong, em, code, link" do
    doc = { "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [
      { "type" => "text", "text" => "bold", "marks" => [{ "type" => "strong" }] },
      { "type" => "text", "text" => " and " },
      { "type" => "text", "text" => "link", "marks" => [{ "type" => "link", "attrs" => { "href" => "https://x.test" } }] }
    ] }] }
    assert_equal "**bold** and [link](https://x.test)", conv(doc)
  end

  test "heading" do
    doc = { "type" => "doc", "content" => [
      { "type" => "heading", "attrs" => { "level" => 2 }, "content" => [{ "type" => "text", "text" => "Title" }] }
    ] }
    assert_equal "## Title", conv(doc)
  end

  test "bullet list" do
    doc = { "type" => "doc", "content" => [
      { "type" => "bulletList", "content" => [
        { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "one" }] }] },
        { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "two" }] }] }
      ] }
    ] }
    assert_equal "- one\n- two", conv(doc)
  end

  test "code block" do
    doc = { "type" => "doc", "content" => [
      { "type" => "codeBlock", "content" => [{ "type" => "text", "text" => "puts 1" }] }
    ] }
    assert_equal "```\nputs 1\n```", conv(doc)
  end

  test "hardBreak inside paragraph" do
    doc = { "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [
      { "type" => "text", "text" => "a" }, { "type" => "hardBreak" }, { "type" => "text", "text" => "b" }
    ] }] }
    assert_equal "a\nb", conv(doc)
  end

  test "unknown node falls back to its inner text" do
    doc = { "type" => "doc", "content" => [
      { "type" => "panel", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "noted" }] }] }
    ] }
    assert_equal "noted", conv(doc)
  end

  test "ordered list numbers items" do
    doc = { "type" => "doc", "content" => [
      { "type" => "orderedList", "content" => [
        { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "first" }] }] },
        { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "second" }] }] }
      ] }
    ] }
    assert_equal "1. first\n2. second", conv(doc)
  end

  test "em, code and strike marks" do
    doc = { "type" => "doc", "content" => [{ "type" => "paragraph", "content" => [
      { "type" => "text", "text" => "a", "marks" => [{ "type" => "em" }] },
      { "type" => "text", "text" => "b", "marks" => [{ "type" => "code" }] },
      { "type" => "text", "text" => "c", "marks" => [{ "type" => "strike" }] }
    ] }] }
    assert_equal "*a*`b`~~c~~", conv(doc)
  end

  test "list item with two paragraphs keeps them separated and indented" do
    doc = { "type" => "doc", "content" => [
      { "type" => "bulletList", "content" => [
        { "type" => "listItem", "content" => [
          { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "A" }] },
          { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "B" }] }
        ] }
      ] }
    ] }
    assert_equal "- A\n\n  B", conv(doc)
  end
end
