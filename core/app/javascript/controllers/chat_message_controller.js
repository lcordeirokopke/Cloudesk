import { Controller } from "@hotwired/stimulus"

// Gera no navegador o client_message_id de cada envio do widget de chat. O mesmo id em um reenvio
// técnico é reconhecido pelo Core, que não grava a mensagem de novo.
export default class extends Controller {
  static targets = ["id"]

  assignId() {
    this.idTarget.value = crypto.randomUUID()
  }
}
