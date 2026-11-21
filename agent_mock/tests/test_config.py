import pytest

from agent_mock.config import Settings


def test_modo_de_falha_desligado_por_padrao():
    settings = Settings.from_env({})

    assert (settings.failure_mode, settings.failure_rate, settings.failure_delay_ms) == ("none", 1.0, 0)


def test_le_as_variaveis_de_falha():
    settings = Settings.from_env({
        "AGENT_FAILURE_MODE": "delay", "AGENT_FAILURE_RATE": "0.25", "AGENT_FAILURE_DELAY_MS": "1500",
    })

    assert (settings.failure_mode, settings.failure_rate, settings.failure_delay_ms) == ("delay", 0.25, 1500)


@pytest.mark.parametrize("mode", ["none", "delay", "drop", "duplicate", "stale"])
def test_aceita_os_modos(mode):
    assert Settings.from_env({"AGENT_FAILURE_MODE": mode}).failure_mode == mode


@pytest.mark.parametrize("env, message", [
    ({"AGENT_FAILURE_MODE": "explode"}, "AGENT_FAILURE_MODE"),
    ({"AGENT_FAILURE_RATE": "1.5"}, "AGENT_FAILURE_RATE"),
    ({"AGENT_FAILURE_RATE": "-0.1"}, "AGENT_FAILURE_RATE"),
    ({"AGENT_FAILURE_DELAY_MS": "-1"}, "AGENT_FAILURE_DELAY_MS"),
])
def test_recusa_configuracao_invalida(env, message):
    with pytest.raises(ValueError, match=message):
        Settings.from_env(env)


def test_taxa_zero_e_aceita():
    assert Settings.from_env({"AGENT_FAILURE_RATE": "0"}).failure_rate == 0.0


def test_janela_da_memoria_padrao():
    assert Settings.from_env({}).memory_window_days == 30


def test_le_a_janela_da_memoria():
    assert Settings.from_env({"AGENT_MEMORY_WINDOW_DAYS": "7"}).memory_window_days == 7
    assert Settings.from_env({"AGENT_MEMORY_WINDOW_DAYS": "0"}).memory_window_days == 0


@pytest.mark.parametrize("value", ["-1", "trinta", "1.5"])
def test_recusa_janela_da_memoria_invalida(value):
    with pytest.raises(ValueError):
        Settings.from_env({"AGENT_MEMORY_WINDOW_DAYS": value})
