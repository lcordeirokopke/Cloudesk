require "rails_helper"

RSpec.describe "Isolamento por marca" do
  it "conecta com o papel da aplicação, sem superusuário, sem BYPASSRLS e sem ser dono" do
    connection = ApplicationRecord.lease_connection
    role = connection.select_one(<<~SQL)
      SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user
    SQL
    owned = connection.select_value(<<~SQL)
      SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tableowner = current_user
    SQL

    expect(role).to eq("rolname" => ENV.fetch("DB_APP_USERNAME"), "rolsuper" => false, "rolbypassrls" => false)
    expect(owned).to eq(0)
  end

  it "tem RLS habilitado e forçado em toda tabela de domínio, e só nelas" do
    rows = ApplicationRecord.lease_connection.select_rows(<<~SQL)
      SELECT relname FROM pg_class
       WHERE relnamespace = 'public'::regnamespace AND relkind = 'r'
         AND relrowsecurity AND relforcerowsecurity
    SQL

    expect(rows.flatten).to match_array(DatabaseHelpers::DOMAIN_MODELS.map(&:table_name))
  end

  it "sem marca definida, nenhuma linha de domínio é visível" do
    DatabaseHelpers::DOMAIN_MODELS.each do |model|
      expect(model.count).to eq(0), "#{model.name} visível sem marca"
    end
  end

  it "sem marca definida, a gravação é recusada" do
    expect_database_error(/row-level security/) do
      Contact.create!(brand_id: infinitepay.id, name: "Sem marca", locale: "pt-BR")
    end
  end

  it "uma marca lê só os próprios dados" do
    jim_contact_id = Tenancy.with_brand(jim) { Contact.first!.id }

    Tenancy.with_brand(infinitepay) do
      expect(Contact.count).to eq(50)
      expect(Contact.distinct.pluck(:brand_id)).to eq([ infinitepay.id ])
      expect(Contact.where(brand_id: jim.id).count).to eq(0)
      expect(Contact.find_by(id: jim_contact_id)).to be_nil
    end
  end

  it "uma marca não grava dados de outra" do
    jim_contact_id = Tenancy.with_brand(jim) { Contact.first!.id }

    Tenancy.with_brand(infinitepay) do
      expect_database_error(/row-level security/) do
        Contact.create!(brand_id: jim.id, name: "Outra marca", locale: "en-US")
      end

      expect(Contact.where(id: jim_contact_id).update_all(name: "alterado")).to eq(0)
      expect(Contact.where(id: jim_contact_id).delete_all).to eq(0)

      own_contact = Contact.first!
      expect_database_error(/row-level security/) do
        Contact.where(id: own_contact.id).update_all(brand_id: jim.id)
      end
    end

    Tenancy.with_brand(jim) do
      expect(Contact.find(jim_contact_id).name).not_to eq("alterado")
    end
  end

  it "a chave estrangeira composta recusa a referência a uma linha de outra marca" do
    jim_conversation = Tenancy.with_brand(jim) do
      Conversation.create!(contact: Contact.first!, channel: "chat")
    end

    Tenancy.with_brand(infinitepay) do
      message = Message.new(
        brand_id: infinitepay.id, conversation_id: jim_conversation.id,
        sequence: 1, channel: "chat", author: "customer", body: "oi"
      )

      # O model não enxerga a conversa da outra marca e recusa a mensagem na validação.
      expect(message).not_to be_valid
      # Sem a validação, o banco recusa pela chave estrangeira composta.
      expect_database_error(/foreign key/) { message.save!(validate: false) }
    end
  end

  it "grava a linha nova com a marca corrente" do
    Tenancy.with_brand(jim) do
      contact = Contact.create!(name: "Synthetic Merchant", locale: "en-US")

      expect(contact.brand_id).to eq(jim.id)
    end
  end

  describe "Tenancy.with_brand" do
    it "limita a marca ao bloco" do
      Tenancy.with_brand(infinitepay) do
        expect(current_setting).to eq(infinitepay.id)
        expect(Tenancy.current_brand_id).to eq(infinitepay.id)
      end

      expect(current_setting).to be_blank
      expect(Tenancy.current_brand_id).to be_nil
    end

    it "restaura a marca anterior ao sair de um bloco aninhado" do
      Tenancy.with_brand(infinitepay) do
        Tenancy.with_brand(jim) do
          expect(current_setting).to eq(jim.id)
          expect(Contact.distinct.pluck(:brand_id)).to eq([ jim.id ])
        end

        expect(current_setting).to eq(infinitepay.id)
        expect(Tenancy.current_brand_id).to eq(infinitepay.id)
        expect(Contact.distinct.pluck(:brand_id)).to eq([ infinitepay.id ])
      end
    end

    it "restaura a marca anterior quando o bloco aninhado levanta erro" do
      Tenancy.with_brand(infinitepay) do
        expect { Tenancy.with_brand(jim) { raise "falha" } }.to raise_error("falha")

        expect(current_setting).to eq(infinitepay.id)
        expect(Tenancy.current_brand_id).to eq(infinitepay.id)
      end
    end

    it "restaura a marca anterior quando o bloco aninhado falha no banco" do
      Tenancy.with_brand(infinitepay) do
        expect do
          Tenancy.with_brand(jim) { ApplicationRecord.lease_connection.execute("SELECT 1 / 0") }
        end.to raise_error(ActiveRecord::StatementInvalid)

        expect(current_setting).to eq(infinitepay.id)
        expect(Tenancy.current_brand_id).to eq(infinitepay.id)
      end
    end

    # O Rails liga o query cache em requisições e jobs.
    it "mantém a marca do bloco externo depois de blocos aninhados com o query cache ligado" do
      connection = ApplicationRecord.lease_connection
      setting = -> { connection.uncached { current_setting(connection) } }

      ApplicationRecord.cache do
        Tenancy.with_brand(infinitepay) do
          2.times do
            Tenancy.with_brand(infinitepay) { expect(setting.call).to eq(infinitepay.id) }
            expect(setting.call).to eq(infinitepay.id)
          end
          Tenancy.with_brand(jim) { expect(setting.call).to eq(jim.id) }

          expect(setting.call).to eq(infinitepay.id)
          expect(Contact.distinct.pluck(:brand_id)).to eq([ infinitepay.id ])
        end
      end
    end

    describe "query cache entre marcas" do
      # As seeds têm o mesmo número de lojistas nas duas marcas; um a mais na JIM diferencia as contagens.
      let!(:counts) do
        Tenancy.with_brand(jim) { Contact.create!(name: "Synthetic Merchant", locale: "en-US") }

        ApplicationRecord.uncached do
          { infinitepay.id => Tenancy.with_brand(infinitepay) { Contact.count },
            jim.id => Tenancy.with_brand(jim) { Contact.count } }
        end
      end

      before { expect(counts[infinitepay.id]).not_to eq(counts[jim.id]) }

      it "a mesma consulta em duas marcas seguidas devolve as linhas de cada marca" do
        result = ApplicationRecord.cache do
          [ Tenancy.with_brand(infinitepay) { Contact.count }, Tenancy.with_brand(jim) { Contact.count } ]
        end

        expect(result).to eq([ counts[infinitepay.id], counts[jim.id] ])
      end

      it "a consulta feita sem marca não é reaproveitada dentro do bloco" do
        result = ApplicationRecord.cache { [ Contact.count, Tenancy.with_brand(infinitepay) { Contact.count } ] }

        expect(result).to eq([ 0, counts[infinitepay.id] ])
      end

      it "o bloco aninhado de outra marca e o bloco externo leem cada um a própria marca" do
        result = ApplicationRecord.cache do
          Tenancy.with_brand(infinitepay) do
            [ Contact.count, Tenancy.with_brand(jim) { Contact.count }, Contact.count ]
          end
        end

        expect(result).to eq([ counts[infinitepay.id], counts[jim.id], counts[infinitepay.id] ])
      end

      it "o bloco que termina com erro não deixa a leitura da outra marca no cache" do
        result = ApplicationRecord.cache do
          Tenancy.with_brand(infinitepay) do
            expect { Tenancy.with_brand(jim) { Contact.count; raise "falha" } }.to raise_error("falha")
            Contact.count
          end
        end

        expect(result).to eq(counts[infinitepay.id])
      end

      it "o bloco aninhado da mesma marca mantém o cache" do
        cached = []
        callback = ->(*, payload) { cached << payload[:sql] if payload[:cached] }

        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          ApplicationRecord.cache do
            Tenancy.with_brand(infinitepay) do
              Contact.count
              Tenancy.with_brand(infinitepay) { Contact.count }
            end
          end
        end

        expect(cached).to include(a_string_matching(/FROM "contacts"/))
      end
    end

    it "recusa marca vazia" do
      expect { Tenancy.with_brand(nil) { } }.to raise_error(ArgumentError)
    end
  end
end
