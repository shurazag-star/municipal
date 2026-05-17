require "test_helper"

class ParserWorkerClientTest < ActiveSupport::TestCase
  test "maps pdf agreement documents to agreement parser command" do
    assert_equal "parse-agreement-pdf", ParserWorkerClient::COMMANDS.fetch("pdf_agreement")
  end
end
