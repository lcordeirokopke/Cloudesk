# Ponto único que define a marca corrente. Todo acesso ao domínio, inclusive leitura, acontece
# dentro de Tenancy.with_brand: o bloco abre a transação e grava a marca em app.brand_id, que as
# políticas de Row-Level Security comparam com brand_id. Fora do bloco, nenhuma linha é visível.
module Tenancy
  SETTING = "app.brand_id".freeze
  STATE_KEY = :tenancy_brand_id

  class << self
    # Aceita um Brand ou o id da marca. O valor vale só para a transação (set_config com
    # is_local = true): o pool reutiliza conexões, e um valor de sessão passaria adiante.
    # O bloco aninhado roda em um savepoint. Quando ele termina sem erro, o valor duraria até o fim
    # da transação externa; por isso o bloco restaura o valor anterior ao sair. Quando ele falha,
    # o rollback até o savepoint desfaz o set_config.
    # A chave do query cache é o SQL e os binds, sem a marca, e o mesmo SQL devolve linhas
    # diferentes em cada marca. Quando o bloco muda a marca, o cache é limpo na entrada e na saída;
    # o bloco aninhado da mesma marca mantém o cache.
    def with_brand(brand)
      brand_id = brand.respond_to?(:id) ? brand.id : brand
      raise ArgumentError, "marca não informada" if brand_id.blank?

      ApplicationRecord.transaction(requires_new: true) do
        previous_setting = read_setting
        previous_state = current_brand_id
        switching = previous_setting.to_s != brand_id.to_s

        write_setting(brand_id)
        connection.clear_query_cache if switching
        self.current_brand_id = brand_id.to_s

        begin
          result = yield
          write_setting(previous_setting)
          result
        ensure
          connection.clear_query_cache if switching
          self.current_brand_id = previous_state
        end
      end
    end

    # Id da marca do bloco corrente, ou nil fora de um bloco.
    def current_brand_id
      ActiveSupport::IsolatedExecutionState[STATE_KEY]
    end

    private

    def current_brand_id=(value)
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = value
    end

    # As duas consultas rodam sem o query cache, que o Rails liga em requisições e jobs: o cache
    # devolveria um valor antigo de current_setting e deixaria de executar um set_config repetido.
    def read_setting
      connection.uncached do
        connection.select_value("SELECT current_setting(#{connection.quote(SETTING)}, true)", "Tenancy")
      end
    end

    def write_setting(value)
      connection.uncached do
        connection.select_value(
          "SELECT set_config(#{connection.quote(SETTING)}, #{connection.quote(value.to_s)}, true)", "Tenancy"
        )
      end
    end

    def connection
      ApplicationRecord.lease_connection
    end
  end
end
