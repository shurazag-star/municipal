require "fileutils"
require "open3"
require "tmpdir"
require "timeout"

class DocxVisualRenderer
  DEFAULT_TIMEOUT_SECONDS = 90

  def initialize(
    soffice: ENV.fetch("SOFFICE_BIN", "soffice"),
    pdfinfo: ENV.fetch("PDFINFO_BIN", "pdfinfo"),
    pdftoppm: ENV.fetch("PDFTOPPM_BIN", "pdftoppm"),
    command_runner: DefaultCommandRunner.new,
    timeout_seconds: DEFAULT_TIMEOUT_SECONDS
  )
    @soffice = soffice
    @pdfinfo = pdfinfo
    @pdftoppm = pdftoppm
    @command_runner = command_runner
    @timeout_seconds = timeout_seconds
  end

  def render(docx_bytes:)
    return invalid("visual_render_docx_missing", "DOCX bytes are empty") if docx_bytes.blank?

    Dir.mktmpdir("docx_visual_render") do |dir|
      input_path = File.join(dir, "input.docx")
      output_dir = File.join(dir, "out")
      FileUtils.mkdir_p(output_dir)
      File.binwrite(input_path, docx_bytes)

      convert_result = run([@soffice, "--headless", "--nologo", "--nofirststartwizard", "--convert-to", "pdf", "--outdir", output_dir, input_path])
      return command_failed("visual_render_convert_failed", "LibreOffice не смог сконвертировать DOCX в PDF", convert_result) unless convert_result.success?

      pdf_path = Dir[File.join(output_dir, "*.pdf")].first
      return invalid("visual_render_pdf_missing", "LibreOffice не создал PDF") if pdf_path.blank? || !File.size?(pdf_path)

      info_result = run([@pdfinfo, pdf_path])
      return command_failed("visual_render_pdfinfo_failed", "Не удалось прочитать PDF после конвертации", info_result) unless info_result.success?

      page_count = info_result.stdout.to_s[/^Pages:\s+(\d+)/, 1].to_i
      return invalid("visual_render_empty_pdf", "PDF после конвертации не содержит страниц") if page_count.zero?

      preview_prefix = File.join(output_dir, "preview")
      preview_result = run([@pdftoppm, "-png", "-f", "1", "-l", "1", pdf_path, preview_prefix])
      return command_failed("visual_render_preview_failed", "Не удалось отрендерить preview PNG", preview_result) unless preview_result.success?

      previews = Dir["#{preview_prefix}-*.png"].select { |path| File.size?(path) }
      return invalid("visual_render_preview_missing", "Preview PNG не создан") if previews.empty?

      {
        "status" => "valid",
        "page_count" => page_count,
        "preview_count" => previews.size,
        "errors" => [],
        "warnings" => []
      }
    end
  rescue Errno::ENOENT => error
    {
      "status" => "missing_dependency",
      "page_count" => 0,
      "preview_count" => 0,
      "errors" => [
        {
          "code" => "visual_render_missing_dependency",
          "message" => "Не найден инструмент визуального рендера: #{error.message}"
        }
      ],
      "warnings" => []
    }
  rescue Timeout::Error
    invalid("visual_render_timeout", "Визуальный render DOCX превысил #{@timeout_seconds} сек.")
  end

  private

  def run(argv)
    @command_runner.call(argv, timeout: @timeout_seconds)
  end

  def command_failed(code, message, result)
    invalid(code, message, stderr: result.stderr.to_s.first(1000))
  end

  def invalid(code, message, extra = {})
    {
      "status" => "invalid",
      "page_count" => 0,
      "preview_count" => 0,
      "errors" => [{ "code" => code, "message" => message }.merge(extra).compact],
      "warnings" => []
    }
  end

  class DefaultCommandRunner
    Result = Struct.new(:stdout, :stderr, :success?, keyword_init: true)

    def call(argv, timeout:)
      stdout = stderr = status = nil
      Timeout.timeout(timeout) do
        stdout, stderr, status = Open3.capture3(*argv)
      end
      Result.new(stdout: stdout, stderr: stderr, success?: status.success?)
    end
  end
end
