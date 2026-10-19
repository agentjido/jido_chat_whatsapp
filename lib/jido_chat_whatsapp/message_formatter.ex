defmodule Jido.Chat.WhatsApp.MessageFormatter do
  @moduledoc """
  Prepares canonical Markdown for WhatsApp at the outbound adapter boundary.

  Only `:markdown` and `"markdown"` enable conversion. Absent, `:plain_text`,
  `:html`, and unknown formats pass through unchanged; HTML rendering is not
  supported. Sends, edits, and selected media captions use this same policy.

  Markdown is parsed with EarmarkParser. Code content is literal; fenced code
  loses its language hint because WhatsApp has no language-aware code blocks.
  Tables become labeled bullet rows, and images become alt text plus their URL.
  Unknown AST containers retain their children. Parser errors or embedded raw
  HTML preserve the entire source rather than risk dropping unsupported content.
  Unmatched inline delimiters remain literal according to the parser.
  """

  @doc "Normalizes canonical format values without creating atoms from input."
  @spec normalize_format(term()) :: :markdown | :plain_text
  def normalize_format(format) when format in [:markdown, "markdown"], do: :markdown
  def normalize_format(_format), do: :plain_text

  @doc "Renders Markdown, or preserves source text for every other format."
  @spec render(String.t() | nil, term()) :: String.t() | nil
  def render(text, format) when is_binary(text) and format in [:markdown, "markdown"] do
    case EarmarkParser.as_ast(text, gfm_tables: true) do
      {:ok, ast, _messages} -> if raw_html?(ast), do: text, else: blocks(ast)
      {:error, _ast, _messages} -> text
    end
  end

  def render(text, _format), do: text

  defp raw_html?(nodes) do
    Enum.any?(nodes, fn
      {_tag, _attrs, children, meta} -> Map.get(meta, :verbatim, false) or raw_html?(children)
      _ -> false
    end)
  end

  defp blocks(nodes), do: Enum.map_join(nodes, "\n\n", &render_node/1)
  defp inline(nodes), do: Enum.map_join(nodes, "", &render_node/1)

  defp render_node(text) when is_binary(text), do: text
  defp render_node({"strong", _, children, _}), do: "*" <> inline(children) <> "*"
  defp render_node({"em", _, children, _}), do: "_" <> inline(children) <> "_"
  defp render_node({"del", _, children, _}), do: "~" <> inline(children) <> "~"
  defp render_node({"p", _, children, _}), do: inline(children)

  defp render_node({heading, _, children, _}) when heading in ["h1", "h2", "h3", "h4", "h5", "h6"],
    do: "*" <> inline(children) <> "*"

  defp render_node({"a", attrs, children, _}), do: link(inline(children), attr(attrs, "href"))
  defp render_node({"img", attrs, _, _}), do: link(attr(attrs, "alt"), attr(attrs, "src"))

  defp render_node({"code", _, children, _}) do
    content = inline(children)
    delimiter = if String.contains?(content, "`"), do: "```", else: "`"
    delimiter <> content <> delimiter
  end

  defp render_node({"pre", _, children, _}) do
    content = Enum.map_join(children, "", fn {"code", _, code, _} -> inline(code) end)
    "```\n" <> content <> "\n```"
  end

  defp render_node({tag, attrs, children, _}) when tag in ["ul", "ol"] do
    start = attrs |> attr("start", "1") |> String.to_integer()

    children
    |> Enum.with_index(start)
    |> Enum.map_join("\n", fn {child, index} ->
      marker = if tag == "ol", do: "#{index}. ", else: "- "
      marker <> String.replace(render_node(child), "\n", "\n" <> String.duplicate(" ", String.length(marker)))
    end)
  end

  defp render_node({"li", _, children, _}) do
    children
    |> Enum.chunk_by(&block?/1)
    |> Enum.map_join("\n", fn group ->
      if block?(hd(group)), do: blocks(group), else: inline(group)
    end)
  end

  defp render_node({"blockquote", _, children, _}) do
    children |> blocks() |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
  end

  defp render_node({"table", _, children, _}) do
    case table_rows(children) do
      [] -> ""
      [header | rows] -> render_table(header, rows)
    end
  end

  defp render_node({"br", _, _, _}), do: "\n"
  defp render_node({"hr", _, _, _}), do: "---"
  defp render_node({_tag, _attrs, children, _}), do: inline(children)

  defp block?({tag, _, _, _}), do: tag in ["p", "ul", "ol", "pre", "blockquote", "table"]
  defp block?(_), do: false

  defp link(label, url) when label == url or label == "", do: url
  defp link(label, ""), do: label
  defp link(label, url), do: label <> " (" <> url <> ")"

  defp attr(attrs, key, default \\ ""), do: attrs |> List.keyfind(key, 0, {key, default}) |> elem(1)

  defp table_rows(nodes) do
    Enum.flat_map(nodes, fn
      {"tr", _, cells, _} -> [Enum.map(cells, &render_node/1)]
      {_tag, _, children, _} -> table_rows(children)
      _ -> []
    end)
  end

  defp render_table(header, []), do: Enum.join(header, " | ")

  defp render_table(header, rows) do
    Enum.map_join(rows, "\n", fn cells ->
      cells
      |> Enum.with_index()
      |> Enum.map_join("; ", fn {value, index} ->
        label = Enum.at(header, index, "")
        label = if label == "", do: "Column #{index + 1}", else: label
        label <> ": " <> value
      end)
      |> then(&("- " <> &1))
    end)
  end
end
