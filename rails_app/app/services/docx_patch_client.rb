require "json"
require "open3"
require "stringio"
require "tempfile"

class DocxPatchClient
  class Error < StandardError; end

  Result = Struct.new(:payload, :bytes, keyword_init: true)

  def initialize(
    root: ENV.fetch("PARSER_WORKER_ROOT", Rails.root.join("../parser_worker").to_s),
    python: ENV.fetch("PARSER_WORKER_PYTHON", "python3")
  )
    @root = Pathname.new(root)
    @python = python
  end

  def patch(source_document: nil, changes:, source_docx_bytes: nil, source_label: nil)
    if source_docx_bytes.blank?
      raise Error, "Файл DOCX не прикреплен" unless source_document&.file_attachment&.attached?

      source_docx_bytes = source_document.file_attachment.download
      source_label ||= source_document.id
    end

    Tempfile.create(["source_docx_#{source_label || 'generated'}", ".docx"]) do |input|
      Tempfile.create(["docx_changes", ".json"]) do |changes_file|
        Tempfile.create(["generated_docx", ".docx"]) do |output|
          input.binmode
          input.write(source_docx_bytes)
          input.flush
          changes_file.write(JSON.pretty_generate(changes))
          changes_file.flush
          output.close

          payload = run_json(
            "patch-docx",
            "--input", input.path,
            "--changes", changes_file.path,
            "--output", output.path
          )
          Result.new(payload: payload, bytes: File.binread(output.path))
        end
      end
    end
  end

  private

  def run_json(*arguments)
    cli = @root.join("cli.py").to_s
    stdout, stderr, status = Open3.capture3({ "PYTHONPATH" => @root.to_s }, @python, cli, *arguments)
    raise Error, stderr.presence || "parser_worker failed with status #{status.exitstatus}" unless status.success?

    JSON.parse(stdout)
  rescue JSON::ParserError => error
    raise Error, "parser_worker returned invalid JSON: #{error.message}"
  end
end
