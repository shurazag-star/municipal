require "json"
require "open3"
require "tempfile"

class ParserWorkerClient
  class Error < StandardError; end

  COMMANDS = {
    "docx_program" => "parse-docx",
    "xlsx_finance" => "parse-xlsx",
    "pdf_procedure" => "parse-procedure-pdf",
    "pdf_agreement" => "parse-agreement-pdf"
  }.freeze

  def initialize(
    root: ENV.fetch("PARSER_WORKER_ROOT", Rails.root.join("../parser_worker").to_s),
    python: ENV.fetch("PARSER_WORKER_PYTHON", "python3")
  )
    @root = Pathname.new(root)
    @python = python
  end

  def parse(document)
    command = COMMANDS.fetch(document.document_type) do
      raise Error, "Неподдерживаемый тип документа: #{document.document_type}"
    end
    raise Error, "Файл не прикреплен" unless document.file_attachment.attached?

    with_attached_tempfile(document) do |path|
      run_json(command, path.to_s)
    end
  end

  def parse_docx_path(path)
    run_json("parse-docx", path.to_s)
  end

  def explain_report(mapping_report, model: nil)
    Tempfile.create(["mapping_report", ".json"]) do |file|
      file.write(JSON.pretty_generate(mapping_report))
      file.flush
      arguments = ["explain-report", "--mapping-report", file.path]
      arguments += ["--model", model] if model.present?
      extra_env = model.present? ? { "OPENROUTER_MODEL_PRIMARY" => model } : {}
      run_json(*arguments, extra_env: extra_env)
    end
  end

  private

  def run_json(*arguments, extra_env: {})
    cli = @root.join("cli.py").to_s
    stdout, stderr, status = Open3.capture3(
      { "PYTHONPATH" => @root.to_s }.merge(extra_env),
      @python,
      cli,
      *arguments
    )
    raise Error, stderr.presence || "parser_worker failed with status #{status.exitstatus}" unless status.success?

    JSON.parse(stdout)
  rescue JSON::ParserError => error
    raise Error, "parser_worker returned invalid JSON: #{error.message}"
  end

  def with_attached_tempfile(document)
    extension = File.extname(document.filename.presence || document.file_attachment.filename.to_s)
    Tempfile.create(["source_document_#{document.id}", extension]) do |file|
      file.binmode
      file.write(document.file_attachment.download)
      file.flush
      yield file.path
    end
  end
end
