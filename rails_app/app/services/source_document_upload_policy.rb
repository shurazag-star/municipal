class SourceDocumentUploadPolicy
  DEFAULT_MAX_BYTES = 100.megabytes

  ALLOWED_EXTENSIONS = {
    "docx_program" => %w[.docx],
    "pdf_procedure" => %w[.pdf],
    "xlsx_finance" => %w[.xlsx .xls .csv],
    "pdf_agreement" => %w[.pdf],
    "other" => %w[.pdf .docx .xlsx .xls .csv]
  }.freeze

  def self.error_for(file:, document_type:)
    new(file: file, document_type: document_type).error_message
  end

  def initialize(file:, document_type:)
    @file = file
    @document_type = document_type.to_s
  end

  def error_message
    return "Выберите файл для загрузки" if file.blank?
    return "Файл слишком большой. Максимальный размер: #{max_megabytes} МБ" if byte_size > max_bytes

    return if allowed_extensions.include?(extension)

    "Неподдерживаемый формат файла. Разрешены: #{allowed_extensions.join(", ")}"
  end

  private

  attr_reader :file, :document_type

  def allowed_extensions
    ALLOWED_EXTENSIONS.fetch(document_type, ALLOWED_EXTENSIONS.fetch("other"))
  end

  def extension
    File.extname(file.original_filename.to_s).downcase
  end

  def byte_size
    return file.size if file.respond_to?(:size) && file.size.present?
    return file.tempfile.size if file.respond_to?(:tempfile) && file.tempfile.respond_to?(:size)

    0
  end

  def max_bytes
    Integer(ENV.fetch("MAX_UPLOAD_BYTES", DEFAULT_MAX_BYTES.to_s))
  rescue ArgumentError
    DEFAULT_MAX_BYTES
  end

  def max_megabytes
    (max_bytes / 1.megabyte.to_f).round
  end
end
