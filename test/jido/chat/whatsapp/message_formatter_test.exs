defmodule Jido.Chat.WhatsApp.MessageFormatterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Chat.WhatsApp.{MessageFormatter, SendOptions}

  @source "**Ready**: *review* the ~~old~~ value. Keep `**literal**` unchanged."
  @rendered "*Ready*: _review_ the ~old~ value. Keep `**literal**` unchanged."

  test "renders canonical emphasis while preserving literal code" do
    assert MessageFormatter.render(@source, :markdown) == @rendered
    assert MessageFormatter.render(@source, "markdown") == @rendered
    assert MessageFormatter.render("__bold__ and _italic_", :markdown) == "*bold* and _italic_"
    assert MessageFormatter.render("``a`b **literal**``", :markdown) == "```a`b **literal**```"
  end

  test "normalizes atom and string keys and values before schema parsing" do
    for opts <- [[format: :markdown], %{format: "markdown"}, %{"format" => "markdown"}] do
      assert SendOptions.new(opts).format == :markdown
    end

    assert SendOptions.new(%{"format" => "markdown", format: :plain_text}).format == :plain_text
    assert SendOptions.new(SendOptions.new(format: :markdown)).format == :markdown
  end

  test "absent, plain, HTML and unknown formats preserve the source" do
    for format <- [nil, :plain_text, "plain_text", :html, "html", :unknown, "Markdown", %{}] do
      assert SendOptions.new(format: format).format == :plain_text
      assert MessageFormatter.render(@source, format) == @source
    end

    assert SendOptions.new([]).format == :plain_text
    assert MessageFormatter.render(nil, :markdown) == nil
  end

  test "headings, paragraphs, nested lists and quotes remain readable" do
    source = "# مرحبا 👋\n\nA **bold** line.\n\n- *one*\n  - two\n- three\n\n3. third\n4. fourth\n\n> quoted\n> text"

    assert MessageFormatter.render(source, :markdown) ==
             "*مرحبا 👋*\n\nA *bold* line.\n\n- _one_\n  - two\n- three\n\n3. third\n4. fourth\n\n> quoted\n> text"
  end

  test "links retain URL destinations and autolinks do not repeat themselves" do
    source = "[Zoë](https://example.com/a_b?q=one&lang=ar) <https://example.com> ![image](https://example.com/a.png)"

    assert MessageFormatter.render(source, :markdown) ==
             "Zoë (https://example.com/a_b?q=one&lang=ar) https://example.com image (https://example.com/a.png)"
  end

  test "tables become labeled bullet rows" do
    source = "| Name | State |\n| --- | --- |\n| Zoë | **Ready** |\n| علي | *Review* |"

    assert MessageFormatter.render(source, :markdown) ==
             "- Name: Zoë; State: *Ready*\n- Name: علي; State: _Review_"
  end

  test "code blocks keep literal content and omit unsupported language labels" do
    assert MessageFormatter.render("```elixir\n**bold** *italic* ~~old~~ & <tag>\n```", :markdown) ==
             "```\n**bold** *italic* ~~old~~ & <tag>\n```"
  end

  test "malformed delimiters and unsupported raw HTML retain their content" do
    for source <- ["**unclosed", "<b>**raw**</b>", "```elixir\nunclosed", "", "---"] do
      assert MessageFormatter.render(source, :markdown) == source
    end
  end

  property "pass-through formats preserve arbitrary UTF-8 source exactly" do
    check all(source <- string(:utf8)) do
      for format <- [nil, :plain_text, :html, "unknown"] do
        assert MessageFormatter.render(source, format) == source
      end
    end
  end

  property "code block contents survive Markdown conversion literally" do
    check all(content <- string(:alphanumeric, min_length: 1)) do
      literal = "**#{content}** _#{content}_ ~~#{content}~~ 👋"
      assert MessageFormatter.render("```text\n#{literal}\n```", :markdown) == "```\n#{literal}\n```"
    end
  end
end
