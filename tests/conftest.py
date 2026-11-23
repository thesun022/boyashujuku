from threading import Thread

import pytest
from waitress import create_server, wasyncore


@pytest.fixture
def live_app(app):
    socket_map = {}
    server = create_server(app, host="127.0.0.1", port=0, map=socket_map)
    thread = Thread(target=server.run, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.effective_port}"
    finally:
        # Windows select() must only see socket closures on its own thread.
        server.trigger.pull_trigger(lambda: wasyncore.close_all(socket_map))
        thread.join(timeout=5)
        server.task_dispatcher.shutdown()
        assert not thread.is_alive()
