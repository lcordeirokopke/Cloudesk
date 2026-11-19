module Channels
  # Formato único das identidades do lojista, para que a busca case qualquer que seja a origem:
  #   whatsapp: telefone em E.164, só dígitos com "+" na frente (o wa_id da Cloud API vem sem "+");
  #   email:    minúsculas, sem espaços nas pontas;
  #   chat:     id do app como chega, sem espaços nas pontas.
  # Devolve nil quando o valor fica vazio.
  module Identity
    module_function

    def normalize(channel, value)
      normalized =
        case channel.to_s
        when "whatsapp"
          digits = value.to_s.gsub(/\D/, "")
          digits.empty? ? "" : "+#{digits}"
        when "email" then value.to_s.strip.downcase
        when "chat" then value.to_s.strip
        else raise ArgumentError, "canal desconhecido: #{channel.inspect}"
        end
      normalized.presence
    end
  end
end
