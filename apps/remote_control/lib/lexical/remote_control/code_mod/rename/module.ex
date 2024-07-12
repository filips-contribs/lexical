defmodule Lexical.RemoteControl.CodeMod.Rename.Module do
  alias Lexical.Ast
  alias Lexical.Ast.Analysis
  alias Lexical.Document
  alias Lexical.Document.Edit
  alias Lexical.Document.Line
  alias Lexical.Document.Position
  alias Lexical.Document.Range
  alias Lexical.Formats
  alias Lexical.RemoteControl.CodeIntelligence.Entity
  alias Lexical.RemoteControl.CodeMod.Rename
  alias Lexical.RemoteControl.Search.Store
  require Logger

  import Line

  @spec recognizes?(Analysis.t(), Position.t()) :: boolean()
  def recognizes?(%Analysis{} = analysis, %Position{} = position) do
    case resolve(analysis, position) do
      {:ok, _, _} ->
        true

      _ ->
        false
    end
  end

  @spec prepare(Analysis.t() | Lexical.path(), Position.t()) ::
          {:ok, {atom(), String.t()}, Range.t()} | {:error, tuple() | atom()}
  def prepare(%Analysis{} = analysis, %Position{} = position) do
    with {:ok, {:module, _module}, _range} <- resolve(analysis, position) do
      {module, range} = surround_the_whole_module(analysis, position)

      if cursor_at_declaration?(module, range) do
        {:ok, {:module, module}, range}
      else
        {:error, {:unsupported_location, :module}}
      end
    end
  end

  @spec rename(Range.t(), String.t(), atom()) :: [Document.Changes.t()]
  def rename(%Range{} = old_range, new_name, module) do
    {old_suffix, new_suffix} = old_range |> range_text() |> diff(new_name)
    results = exacts(module, old_suffix) ++ descendants(module, old_suffix)

    for {uri, entries} <- Enum.group_by(results, &Document.Path.ensure_uri(&1.path)),
        result = to_document_changes(uri, entries, new_suffix),
        match?({:ok, _}, result) do
      {:ok, document_changes} = result
      document_changes
    end
  end

  defp resolve(%Analysis{} = analysis, %Position{} = position) do
    case Entity.resolve(analysis, position) do
      {:ok, {module_or_struct, module}, range} when module_or_struct in [:struct, :module] ->
        {:ok, {:module, module}, range}

      _ ->
        {:error, :not_a_module}
    end
  end

  defp resolve(path, %Position{} = position) do
    uri = Document.Path.ensure_uri(path)

    with {:ok, _} <- Document.Store.open_temporary(uri),
         {:ok, _document, analysis} <- Document.Store.fetch(uri, :analysis) do
      resolve(analysis, position)
    end
  end

  defp cursor_at_declaration?(module, rename_range) do
    case Store.exact(module, type: :module, subtype: :definition) do
      {:ok, [definition]} ->
        rename_range == definition.range

      _ ->
        false
    end
  end

  defp surround_the_whole_module(analysis, position) do
    # When renaming occurs, we want users to be able to choose any place in the defining module,
    # not just the last local module, like: `defmodule |Foo.Bar do` also works.
    {:ok, %{end: {_end_line, end_character}}} = Ast.surround_context(analysis, position)
    end_position = %{position | character: end_character - 1}
    {:ok, {:module, module}, range} = resolve(analysis, end_position)
    {module, range}
  end

  defp diff(old_range_text, new_name) do
    diff = String.myers_difference(old_range_text, new_name)

    eq =
      if match?([{:eq, _eq} | _], diff) do
        diff |> hd() |> elem(1)
      else
        ""
      end

    old_suffix = String.replace(old_range_text, ~r"^#{eq}", "")
    new_suffix = String.replace(new_name, ~r"^#{eq}", "")
    {old_suffix, new_suffix}
  end

  defp exacts(module, old_suffix) do
    module
    |> query_for_exacts()
    |> Enum.filter(&entry_matching?(&1, old_suffix))
    |> adjust_range_for_exacts(old_suffix)
  end

  defp descendants(module, old_suffix) do
    module
    |> query_for_descendants()
    |> Enum.filter(&(entry_matching?(&1, old_suffix) and has_dots_in_range?(&1)))
    |> adjust_range_for_descendants(module, old_suffix)
  end

  defp query_for_exacts(module) do
    module_string = Formats.module(module)

    case Store.exact(module_string, type: :module) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  defp query_for_descendants(module) do
    module_string = Formats.module(module)
    prefix = "#{module_string}."

    case Store.prefix(prefix, type: :module) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  defp maybe_rename_file(document, entries, new_suffix) do
    entries
    |> Enum.map(&Rename.File.maybe_rename(document, &1, new_suffix))
    # every group should have only one `rename_file`
    |> Enum.find(&(not is_nil(&1)))
  end

  defp entry_matching?(entry, old_suffix) do
    entry.range |> range_text() |> String.contains?(old_suffix)
  end

  defp has_dots_in_range?(entry) do
    entry.range |> range_text() |> String.contains?(".")
  end

  defp adjust_range_for_exacts(entries, old_suffix) do
    old_suffix_length = String.length(old_suffix)

    for entry <- entries do
      start_character = entry.range.end.character - old_suffix_length
      put_in(entry.range.start.character, start_character)
    end
  end

  defp adjust_range_for_descendants(entries, module, old_suffix) do
    for entry <- entries,
        range_text = range_text(entry.range),
        matches = matches(range_text, old_suffix),
        result = resolve_module_range(entry, module, matches),
        match?({:ok, _}, result) do
      {_, range} = result
      %{entry | range: range}
    end
  end

  defp range_text(range) do
    line(text: text) = range.end.context_line
    String.slice(text, range.start.character - 1, range.end.character - range.start.character)
  end

  defp resolve_module_range(_entry, _module, []) do
    {:error, :not_found}
  end

  defp resolve_module_range(entry, module, [[{start, length}]]) do
    range = adjust_range_characters(entry.range, {start, length})

    with {:ok, {:module, ^module}, _} <- resolve(entry.path, range.start) do
      {:ok, range}
    end
  end

  defp resolve_module_range(entry, module, [[{start, length}] | tail] = _matches) do
    # This function is mainly for the duplicated suffixes
    # For example, if we have a module named `Foo.Bar.Foo.Bar` and we want to rename it to `Foo.Bar.Baz`
    # The `Foo.Bar` will be duplicated in the range text, so we need to resolve the correct range
    # and only rename the second occurrence of `Foo.Bar`
    start_character = entry.range.start.character + start
    position = %{entry.range.start | character: start_character}

    with {:ok, {:module, result}, range} <- resolve(entry.path, position) do
      if result == module do
        range = adjust_range_characters(range, {start, length})
        {:ok, range}
      else
        resolve_module_range(entry, module, tail)
      end
    end
  end

  defp matches(range_text, "") do
    # When expanding a module, the old_suffix is an empty string,
    # so we need to scan the module before the period
    for [{start, length}] <- Regex.scan(~r/\w+(?=\.)/, range_text, return: :index) do
      [{start + length, 0}]
    end
  end

  defp matches(range_text, old_suffix) do
    Regex.scan(~r/#{old_suffix}/, range_text, return: :index)
  end

  defp adjust_range_characters(%Range{} = range, {start, length} = _matched_old_suffix) do
    start_character = range.start.character + start
    end_character = start_character + length

    range
    |> put_in([:start, :character], start_character)
    |> put_in([:end, :character], end_character)
  end

  defp to_document_changes(uri, entries, new_suffix) do
    edits = Enum.map(entries, &Edit.new(new_suffix, &1.range))

    with {:ok, document} <- Document.Store.open_temporary(uri) do
      rename_file = maybe_rename_file(document, entries, new_suffix)
      {:ok, Document.Changes.new(document, edits, rename_file)}
    end
  end
end