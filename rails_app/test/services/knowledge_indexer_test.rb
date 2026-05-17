require "test_helper"

class KnowledgeIndexerTest < ActiveSupport::TestCase
  setup do
    @user = create_isolated_user!(email: "knowledge-indexer@example.com")
    @organization = @user.organization
    @document = SourceDocument.create!(
      organization: @organization,
      created_by: @user,
      document_type: "pdf_procedure",
      filename: "Порядок.pdf",
      status: "parsed",
      parsed_payload: {
        "chunks" => [
          {
            "chunk_type" => "approval_terms",
            "title" => "Срок согласования",
            "content" => "Согласование проекта выполняется в течение 5 рабочих дней.",
            "page_number" => 7,
            "metadata" => { "keywords" => ["согласование"] }
          }
        ]
      }
    )
  end

  test "indexes parsed procedure chunks for the document organization" do
    assert_difference "KnowledgeChunk.count", 1 do
      KnowledgeIndexer.new(@document).index!
    end

    chunk = @organization.knowledge_chunks.sole
    assert_equal @document, chunk.source_document
    assert_equal "approval_terms", chunk.chunk_type
    assert_equal "Срок согласования", chunk.title
    assert_equal 7, chunk.page_number
    assert_includes chunk.content, "5 рабочих дней"
    assert_equal ["согласование"], chunk.metadata["keywords"]
  end

  test "replaces stale chunks on reindex" do
    stale = @organization.knowledge_chunks.create!(
      source_document: @document,
      chunk_type: "procedure_general",
      title: "Старый фрагмент",
      content: "Старый текст"
    )

    KnowledgeIndexer.new(@document).index!

    assert_not KnowledgeChunk.exists?(stale.id)
    assert_equal ["approval_terms"], @document.knowledge_chunks.pluck(:chunk_type)
  end

  test "falls back to legacy rules when parser chunks are absent" do
    @document.update!(
      parsed_payload: {
        "rules" => ["Муниципальная программа является документом стратегического планирования"]
      }
    )

    KnowledgeIndexer.new(@document).index!

    chunk = @organization.knowledge_chunks.sole
    assert_equal "procedure_general", chunk.chunk_type
    assert_includes chunk.content, "стратегического планирования"
  end
end
