Configure or create a Google project at https://console.developers.google.com/project.

Under "APIs and auth" -> "APIs", enable the "Google+ API".

Under "APIs and auth" -> "Credentials", create a new Client ID. Add this lines as redirect URIs:

    http://127.0.0.1:4567/auth/google/callback

Back in this application, copy the environment configuration and configure it:

    cp .env.example .env && vi .env

Start memcache:

    memcached -v

Start the server:

    ruby app.rb

Open your browser:

    open 127.0.0.1:4567/
