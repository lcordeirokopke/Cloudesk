# Todo e-mail que chega ao Action Mailbox vai ao SupportMailbox. O filtro de quais e-mails entram
# fica no Channels::Email::IngestJob, que só cria o InboundEmail de e-mails endereçados a um e-mail
# de suporte de uma marca.
class ApplicationMailbox < ActionMailbox::Base
  routing all: :support
end
