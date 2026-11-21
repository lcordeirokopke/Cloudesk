# Apoio aos testes do admin de filas e regras: credenciais do basic auth próprias dos testes,
# definidas no ambiente durante cada exemplo, headers autorizados e escolha da marca na sessão.
module AdminHelpers
  ADMIN_USER = "operator-a".freeze
  ADMIN_PASSWORD = "admin-password-de-teste".freeze

  def admin_headers(user = ENV["ADMIN_USER"], password = ENV["ADMIN_PASSWORD"])
    {
      "User-Agent" => ChannelHelpers::MODERN_BROWSER,
      "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(user.to_s, password.to_s)
    }
  end

  def admin_sign_in(brand)
    post "/admin/session", params: { brand: brand.slug }, headers: admin_headers
  end
end

RSpec.shared_context "admin" do
  # As credenciais são lidas do ambiente a cada requisição; o teste usa valores próprios.
  around do |example|
    previous = ENV.values_at("ADMIN_USER", "ADMIN_PASSWORD")
    ENV["ADMIN_USER"] = AdminHelpers::ADMIN_USER
    ENV["ADMIN_PASSWORD"] = AdminHelpers::ADMIN_PASSWORD
    example.run
  ensure
    ENV["ADMIN_USER"], ENV["ADMIN_PASSWORD"] = previous
  end
end

RSpec.configure do |config|
  config.include AdminHelpers, type: :request
end
