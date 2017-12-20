{% extends "./common/README.md" %}

{% block quick_start %}
nvm install {{NODE_VERSION}}
nvm use {{NODE_VERSION}}
npm install
npm build
{% endblock quick_start %}

{% block content %} {% endblock %}