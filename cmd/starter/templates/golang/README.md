{% extends "./common/README.md" %}

# Quick Start

{% block quick_start %}
brew install golang # Expected Version: {{GOLANG_VERSION}}
make install

make
{% endblock quick_start %}

{% block content %} {% endblock %}