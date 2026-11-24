# Apoio aos testes da tela da DLQ: endereço e segredo dos endpoints da DLQ no broker-web, e
# mensagens da DLQ no formato da listagem do Broker.
module DlqHelpers
  ENVIRONMENT = {
    "BROKER_DLQ_URL" => "http://broker-dlq.test:3000",
    "BROKER_DLQ_SECRET" => "broker-dlq-secret-de-teste"
  }.freeze

  def dlq_url(path)
    "#{ENVIRONMENT.fetch('BROKER_DLQ_URL')}#{path}"
  end

  # Mensagem da DLQ como Broker::DlqEndpoints a lista.
  def dlq_listed_message(partition:, offset:, key:, brand: "infinitepay", reason: "core_rejected", status: "422",
                         failed_at: "2026-11-23T14:00:00.000Z")
    {
      "partition" => partition, "offset" => offset, "key" => key,
      "headers" => {
        "brand" => brand, "dlq_reason" => reason, "dlq_status" => status, "dlq_source_topic" => "agent.outbound",
        "dlq_source_partition" => "2", "dlq_source_offset" => "11", "dlq_failed_at" => failed_at
      }.compact,
      "value" => "{}", "type" => "reply", "inbound_event_id" => "01a1f8e8-565d-72e6-b85d-0926153aaf49",
      "timestamp" => failed_at
    }
  end

  def stub_dlq_list(brand, messages, limit: 50)
    stub_request(:get, dlq_url("/dlq/messages")).with(query: { brand: brand.slug, limit: limit.to_s })
                                                 .to_return(status: 200, body: JSON.generate("messages" => messages))
  end

  # Resposta 200 da republicação da mensagem na posição.
  def stub_dlq_reprocess(partition, offset, destination_offset: 40)
    body = {
      "source" => { "topic" => "agent.dlq", "partition" => partition, "offset" => offset },
      "destination" => { "topic" => "agent.outbound", "partition" => 2, "offset" => destination_offset },
      "diagnostics" => {
        "dlq_reason" => "core_rejected", "dlq_status" => "422", "dlq_source_topic" => "agent.outbound",
        "dlq_source_partition" => "2", "dlq_source_offset" => "11", "dlq_failed_at" => "2026-11-23T14:00:00.000Z"
      }
    }
    stub_request(:post, dlq_url("/dlq/messages/#{partition}/#{offset}/reprocess"))
      .to_return(status: 200, body: JSON.generate(body))
  end
end

RSpec.configure do |config|
  config.include DlqHelpers
  config.before(:suite) { ENV.update(DlqHelpers::ENVIRONMENT) }
end
