{% extends "./common/README.md" %}

{% block quick_start %}
brew install python3 # Expected version: {{PYTHON_VERSION}}
VIRTUALENV_HOME=$HOME/venv

python3 -m venv $VIRTUALENV_HOME/{{PROJECT_NAME}}
workon {{PROJECT_NAME}}
pip install requirements.txt
{% endblock quick_start %}

{% block content %} {% endblock %}