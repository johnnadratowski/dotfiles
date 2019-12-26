# Architecture Docs

This documentation uses asciidoc and asciidoctor to achieve it's rendering.  In order to do that, you'll have to set up ruby on your local system, and gem install asciidoctor and asciidoctor-diagram.

[Docs are deployed here](http://unified-engineering.s3-website-us-east-1.amazonaws.com/hosted-docs/)

## Quick Start

*Install the Intellij/Pycharm plugin for asciidoc, as it will automatically compile, render, and preview in the IDE.*

```sh
brew install ruby

# Install ruby deps
bundle

# Compile the documentation to the output directory (./public by default)
./build.sh

# watch + compile on .adoc change, also opens up browser with live reload on change
./watch.sh

# Deploy the compiled docs to s3
./deploy.sh
```
