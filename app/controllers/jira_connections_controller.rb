# The single Jira credentials record used to import tickets. Singleton: edit
# always operates on the one row (or builds it). A blank api_token on update is
# ignored so saving other fields never wipes the stored secret.
class JiraConnectionsController < ApplicationController
  def edit
    @connection = JiraConnection.current_or_new
  end

  def update
    @connection = JiraConnection.current_or_new
    attrs = connection_params
    attrs = attrs.except(:api_token) if attrs[:api_token].blank?
    if @connection.update(attrs)
      redirect_to edit_jira_connection_path, notice: "Jira connection saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def connection_params
    params.require(:jira_connection).permit(:site_url, :email, :api_token)
  end
end
