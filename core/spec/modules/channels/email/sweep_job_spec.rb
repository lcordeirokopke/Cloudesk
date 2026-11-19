require "rails_helper"

RSpec.describe Channels::Email::SweepJob do
  let(:search_url) { "http://mailpit.test/api/v1/search" }

  def page(ids, total)
    { "messages" => ids.map { |id| { "ID" => id } }, "messages_count" => ids.size, "total" => total }.to_json
  end

  def ingested_ids
    jobs_of(Channels::Email::IngestJob).order(:id).map { |job| job.arguments.fetch("arguments").first }
  end

  it "enfileira um IngestJob por mensagem sem tag" do
    stub_request(:get, search_url).with(query: { query: "!is:tagged", start: "0", limit: "50" })
                                  .to_return(status: 200, body: page(%w[a b], 2))

    expect { described_class.perform_now }.to change { jobs_of(Channels::Email::IngestJob).count }.by(2)
    expect(ingested_ids.last(2)).to eq(%w[a b])
  end

  it "percorre as páginas da busca" do
    first_page = (1..50).map { |index| "p#{index}" }
    stub_request(:get, search_url).with(query: { query: "!is:tagged", start: "0", limit: "50" })
                                  .to_return(status: 200, body: page(first_page, 51))
    stub_request(:get, search_url).with(query: { query: "!is:tagged", start: "50", limit: "50" })
                                  .to_return(status: 200, body: page(%w[p51], 51))

    expect { described_class.perform_now }.to change { jobs_of(Channels::Email::IngestJob).count }.by(51)
  end

  it "não enfileira nada sem mensagens sem tag" do
    stub_request(:get, search_url).with(query: hash_including("query" => "!is:tagged")).to_return(status: 200, body: page([], 0))

    expect { described_class.perform_now }.not_to(change { jobs_of(Channels::Email::IngestJob).count })
  end
end
