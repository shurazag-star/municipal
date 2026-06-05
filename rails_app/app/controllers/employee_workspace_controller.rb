class EmployeeWorkspaceController < ApplicationController
  before_action :require_employee!

  def show
    @context = AgentContextBuilder.new(organization: current_organization, user: current_user).build
    @conversation = AgentConversation.active_for!(organization: current_organization, user: current_user, audience: "employee")
    @conversation.update!(context_snapshot: @context)
    @messages = @conversation.agent_messages.where(role: %w[user assistant]).order(:created_at, :id)
    @active_agent_task = @conversation.agent_tasks
      .where(status: %w[queued running])
      .order(updated_at: :desc)
      .first
    @upload_slots = upload_slots
    @approved_change_sets = approved_change_sets
  end

  private

  def require_employee!
    redirect_to root_path if current_user&.admin?
  end

  def upload_slots
    [
      {
        key: "procedure",
        title: "Порядок разработки",
        hint: "PDF с порядком разработки и внесения изменений",
        document: latest_document("pdf_procedure")
      },
      {
        key: "program",
        title: "Текущая редакция программы",
        hint: "DOCX действующей муниципальной программы",
        document: active_generated_change_set ? nil : latest_document("docx_program"),
        filename: active_generated_change_set&.generated_docx_attachment&.filename&.to_s
      },
      {
        key: "change_source",
        title: "Документ-основание",
        hint: "Excel финансистов или PDF-основание. Если его нет, опишите изменение в чате.",
        document: latest_change_source
      }
    ]
  end

  def latest_document(type)
    employee_source_documents.where(document_type: type).order(updated_at: :desc, id: :desc).first
  end

  def latest_change_source
    employee_source_documents
      .where(document_type: %w[xlsx_finance pdf_agreement])
      .order(updated_at: :desc, id: :desc)
      .first
  end

  def active_generated_change_set
    @active_generated_change_set ||= begin
      version = current_program&.current_version
      if version&.approved_active_status?
        ChangeSet.where(target_program_version: version, status: "applied")
          .order(updated_at: :desc, id: :desc)
          .detect(&:export_ready?)
      end
    end
  end

  def current_program
    @current_program ||= begin
      document = latest_document("docx_program")
      version = if document
        current_organization.program_versions
          .where("program_versions.import_summary ->> 'source_document_id' = ?", document.id.to_s)
          .order(:id)
          .last
      end
      version&.municipal_program || current_organization.municipal_programs
        .includes(:current_version)
        .order(updated_at: :desc, id: :desc)
        .first
    end
  end

  def employee_source_documents
    current_organization.source_documents.where(created_by: current_user)
  end

  def approved_change_sets
    ChangeSet.joins(program_version: :municipal_program)
      .where(municipal_programs: { organization_id: current_organization.id })
      .where(status: "applied")
      .order(updated_at: :desc)
      .first(12)
  end
end
