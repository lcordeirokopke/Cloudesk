# Extração dos dados do Core para a análise do experimento de carga. Só leitura: em
# Tenancy.with_brand de cada marca, lê o domínio com COPY (SELECT ...) TO STDOUT pela conexão da
# transação, que obedece ao RLS do papel da aplicação, e não grava nada no banco.
#   bin/rails experiment:export DIR=<pasta>
#
# Grava em DIR um CSV por consulta, com um cabeçalho só e a marca na coluna brand. Os horários estão
# em UTC, em ISO 8601.
#
# | Arquivo | Linhas |
# | - | - |
# | customer_messages.csv | Mensagens do lojista, com o event_id, o trace_id e o received_at do message.created |
# | actions.csv | Ações do agente: aceitas (agent.reply, agent.escalate, agent.categorize, agent.resolve) e recusadas (agent.action.stale, agent.action.rejected), com os carimbos de cada salto |
# | deliveries.csv | message.delivered, com o autor da mensagem e a sequência respondida |
# | events.csv | conversation.routed, conversation.escalated e webhook.skipped; em queue, a fila do roteamento ou o destino da escalação |
module ExperimentExport
  ACTION_EVENTS = %w[agent.reply agent.escalate agent.categorize agent.resolve agent.action.stale agent.action.rejected].freeze
  OTHER_EVENTS = %w[conversation.routed conversation.escalated webhook.skipped].freeze

  # Arquivo => consulta. {brand} recebe o slug entre aspas, {actions} e {events}, as listas acima, e
  # {utc:<coluna>}, o horário da coluna em ISO 8601.
  QUERIES = {
    "customer_messages.csv" => <<~SQL,
      SELECT {brand} AS brand, m.id AS message_id, m.external_id, m.channel, m.conversation_id, m.sequence,
             {utc:m.created_at} AS created_at, c.state AS conversation_state,
             e.event_id, e.trace_id, e.payload ->> 'received_at' AS received_at
      FROM messages m
      JOIN conversations c ON c.id = m.conversation_id
      LEFT JOIN audit_events e ON e.action = 'message.created' AND e.target_type = 'Message' AND e.target_id = m.id
      WHERE m.author = 'customer'
      ORDER BY m.id
    SQL
    "actions.csv" => <<~SQL,
      SELECT {brand} AS brand, e.action, e.payload #>> '{payload,action,type}' AS type, e.conversation_id,
             e.payload #>> '{payload,action,inbound_event_id}' AS inbound_event_id,
             e.payload #>> '{payload,action,based_on_sequence}' AS based_on_sequence,
             e.payload #>> '{payload,idempotency_key}' AS idempotency_key,
             e.payload #>> '{payload,action,timestamps,broker_received_at}' AS broker_received_at,
             e.payload #>> '{payload,action,timestamps,kafka_appended_at}' AS kafka_appended_at,
             e.payload #>> '{payload,action,timestamps,agent_consumed_at}' AS agent_consumed_at,
             e.payload #>> '{payload,action,timestamps,agent_published_at}' AS agent_published_at,
             e.payload #>> '{payload,action,model,parameters,artificial_latency_ms}' AS artificial_latency_ms,
             e.payload ->> 'received_at' AS received_at
      FROM audit_events e
      WHERE e.action IN ({actions})
      ORDER BY e.id
    SQL
    "deliveries.csv" => <<~SQL,
      SELECT {brand} AS brand, m.id AS message_id, m.author, m.channel, m.conversation_id,
             created.payload #>> '{payload,in_reply_to_sequence}' AS in_reply_to_sequence,
             e.payload #>> '{payload,delivered_at}' AS delivered_at
      FROM audit_events e
      JOIN messages m ON m.id = e.target_id
      LEFT JOIN audit_events created
        ON created.action = 'message.created' AND created.target_type = 'Message' AND created.target_id = m.id
      WHERE e.action = 'message.delivered' AND e.target_type = 'Message'
      ORDER BY e.id
    SQL
    "events.csv" => <<~SQL
      SELECT {brand} AS brand, e.action, e.conversation_id, e.target_id, e.reason,
             e.payload #>> '{payload,first_attendant}' AS first_attendant,
             coalesce(e.payload #>> '{payload,queue}', e.payload #>> '{payload,to_queue}') AS queue,
             {utc:e.created_at} AS created_at
      FROM audit_events e
      WHERE e.action IN ({events})
      ORDER BY e.id
    SQL
  }.freeze

  module_function

  # Grava os CSV em dir e devolve { arquivo => número de linhas, sem o cabeçalho }.
  def run(dir:)
    raise ArgumentError, "informe DIR=<pasta>" if dir.to_s.strip.empty?

    destination = Pathname(dir.to_s.strip)
    FileUtils.mkdir_p(destination)
    brands = Brand.order(:slug).to_a

    QUERIES.to_h do |file, query|
      rows = File.open(destination.join(file), "wb") do |io|
        brands.each_with_index.sum { |brand, index| copy(brand, query, io, header: index.zero?) }
      end
      [ file, rows ]
    end
  end

  # Copia o resultado da consulta na marca; devolve o número de linhas sem o cabeçalho.
  def copy(brand, query, io, header:)
    Tenancy.with_brand(brand) do
      connection = ApplicationRecord.lease_connection
      raw = connection.raw_connection
      rows = header ? -1 : 0
      raw.copy_data("COPY (#{sql(connection, brand, query)}) TO STDOUT WITH (FORMAT csv, HEADER #{header})") do
        while (line = raw.get_copy_data)
          io.write(line)
          rows += 1
        end
      end
      rows
    end
  end

  def sql(connection, brand, query)
    query.gsub("{brand}", connection.quote(brand.slug))
         .gsub("{actions}", list(connection, ACTION_EVENTS))
         .gsub("{events}", list(connection, OTHER_EVENTS))
         .gsub(/\{utc:([\w.]+)\}/) { %(to_char(#{Regexp.last_match(1)}, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) }
  end

  def list(connection, values)
    values.map { |value| connection.quote(value) }.join(", ")
  end
end

namespace :experiment do
  desc "Exporta em CSV, para a pasta DIR, as mensagens, ações, entregas e eventos do experimento"
  task export: :environment do
    ExperimentExport.run(dir: ENV["DIR"]).each { |file, rows| puts "#{file}: #{rows} linhas" }
  end
end
