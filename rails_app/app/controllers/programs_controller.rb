class ProgramsController < ApplicationController
  before_action :require_admin!

  def index
    @programs = current_organization.municipal_programs.order(updated_at: :desc)
  end

  def show
    @program = current_organization.municipal_programs.find_by(id: params[:id])
    head :not_found unless @program
  end

  def create
    program = MunicipalProgram.create!(
      organization: current_organization,
      name: params[:name].presence || "Новая муниципальная программа",
      period_start_year: params[:period_start_year].presence || 2026,
      period_end_year: params[:period_end_year].presence || 2030
    )
    AuditLog.record!(current_user, current_organization, "municipal_program.created", program)
    redirect_to program_path(program)
  end
end
