{% extends "./common/README.md" %}

{% block content %}

# Quick Start

```sh
VIRTUALENV_HOME=$HOME/venv

python3 -m venv $VIRTUALENV_HOME/{{PROJECT_NAME}}
workon {{PROJECT_NAME}}
pip install requirements.txt
```

{% endblock %}