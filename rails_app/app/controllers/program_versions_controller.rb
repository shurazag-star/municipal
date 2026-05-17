class ProgramVersionsController < ApplicationController
  before_action :require_admin!

  def show
    @program_version = current_organization.program_versions.find_by(id: params[:id])
    unless @program_version
      head :not_found
      return
    end

    @nodes = @program_version.program_nodes.includes(:funding_lines).order(:id)
  end
end
