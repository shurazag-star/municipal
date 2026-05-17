require "test_helper"

class DocxVisualRendererTest < ActiveSupport::TestCase
  test "renders docx bytes through libreoffice pdf and png preview pipeline" do
    runner = FakeCommandRunner.new

    result = DocxVisualRenderer.new(command_runner: runner).render(docx_bytes: "fake-docx")

    assert_equal "valid", result["status"]
    assert_equal 2, result["page_count"]
    assert_equal 1, result["preview_count"]
    assert_equal "soffice", runner.commands[0].first
    assert_equal "pdfinfo", runner.commands[1].first
    assert_equal "pdftoppm", runner.commands[2].first
  end

  test "returns missing dependency when soffice is unavailable" do
    result = DocxVisualRenderer.new(command_runner: MissingCommandRunner.new).render(docx_bytes: "fake-docx")

    assert_equal "missing_dependency", result["status"]
    assert_equal "visual_render_missing_dependency", result["errors"].first["code"]
  end

  class FakeCommandRunner
    Result = Struct.new(:stdout, :stderr, :success?, keyword_init: true)

    attr_reader :commands

    def initialize
      @commands = []
    end

    def call(argv, chdir: nil, timeout: nil)
      @commands << argv
      case argv.first
      when "soffice"
        outdir = argv[argv.index("--outdir") + 1]
        File.binwrite(File.join(outdir, "input.pdf"), "%PDF-1.4\n")
        Result.new(stdout: "convert ok", stderr: "", success?: true)
      when "pdfinfo"
        Result.new(stdout: "Pages: 2\n", stderr: "", success?: true)
      when "pdftoppm"
        prefix = argv.last
        File.binwrite("#{prefix}-1.png", "PNG")
        Result.new(stdout: "", stderr: "", success?: true)
      else
        Result.new(stdout: "", stderr: "unknown", success?: false)
      end
    end
  end

  class MissingCommandRunner
    def call(*)
      raise Errno::ENOENT, "soffice"
    end
  end
end
