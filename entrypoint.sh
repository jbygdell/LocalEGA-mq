#!/bin/bash

[[ -z "${MQ_USER}" ]] && echo 'Environment variable MQ_USER is empty' 1>&2 && exit 1
[[ -z "${MQ_PASSWORD_HASH}" ]] && echo 'Environment variable MQ_PASSWORD_HASH is empty' 1>&2 && exit 1
[[ -z "${CEGA_CONNECTION}" ]] && echo 'Environment variable CEGA_CONNECTION is empty' 1>&2 && exit 1


cat >> /etc/rabbitmq/rabbitmq.conf <<EOF
listeners.ssl.default = 5671
ssl_options.cacertfile = ${MQ_CA:-/etc/rabbitmq/ssl/ca.pem}
ssl_options.certfile = ${MQ_SERVER_CERT:-/etc/rabbitmq/ssl/mq-server.pem}
ssl_options.keyfile = ${MQ_SERVER_KEY:-/etc/rabbitmq/ssl/mq-server-key.pem}
ssl_options.verify = verify_peer
ssl_options.fail_if_no_peer_cert = true
ssl_options.versions.1 = tlsv1.2
disk_free_limit.absolute = 1GB
management.listener.port = 15672
management.load_definitions = /etc/rabbitmq/definitions.json
EOF

chown rabbitmq:rabbitmq /etc/rabbitmq/rabbitmq.conf
chmod 600 /etc/rabbitmq/rabbitmq.conf

cat > /etc/rabbitmq/definitions.json <<EOF
{
  "users": [
    {
      "name": "${MQ_USER}", "password_hash": "${MQ_PASSWORD_HASH}",
      "hashing_algorithm": "rabbit_password_hashing_sha256", "tags": "administrator"
    }
  ],
  "vhosts": [
    { "name": "/" }
  ],
  "permissions": [
    { "user": "${MQ_USER}", "vhost": "/", "configure": ".*", "write": ".*", "read": ".*" }
  ],
  "parameters": [
    {
      "name": "CEGA-ids", "vhost": "/", "component": "federation-upstream",
      "value": { "ack-mode": "on-confirm", "queue": "v1.stableIDs", "trust-user-id": false, "uri": "${CEGA_CONNECTION}" }
    },
    {
      "name": "CEGA-files", "vhost": "/", "component": "federation-upstream",
      "value": { "ack-mode": "on-confirm", "queue": "v1.files", "trust-user-id": false, "uri": "${CEGA_CONNECTION}" }
    }
  ],
  "policies": [
    {
      "vhost": "/", "name": "CEGA-files", "pattern": "files", "apply-to": "queues", "priority": 0,
      "definition": { "federation-upstream": "CEGA-files" }
    },
    {
      "vhost": "/", "name": "CEGA-ids", "pattern": "stableIDs", "apply-to": "queues", "priority": 0,
      "definition": { "federation-upstream": "CEGA-ids" }
    }
  ],
  "queues": [
    {"name": "stableIDs", "vhost": "/", "durable": true, "auto_delete": false, "arguments":{}},
    {"name": "files",     "vhost": "/", "durable": true, "auto_delete": false, "arguments":{}},
    {"name": "archived",  "vhost": "/", "durable": true, "auto_delete": false, "arguments":{}}
  ],
  "exchanges": [
    {"name":"cega", "vhost":"/", "type":"topic", "durable":true, "auto_delete":false, "internal":false, "arguments":{}}, 
    {"name":"lega", "vhost":"/", "type":"topic", "durable":true, "auto_delete":false, "internal":false, "arguments":{}}
  ], 
  "bindings": [
    { "source":"lega", "vhost": "/", "destination":"archived", "destination_type":"queue", "routing_key":"archived", "arguments":{}}
  ]
}
EOF
chown rabbitmq:rabbitmq /etc/rabbitmq/definitions.json
chmod 600 /etc/rabbitmq/definitions.json

cat > /etc/rabbitmq/advanced.config <<EOF
[
  {rabbit,
    [{tcp_listeners, []}
  ]},
  {rabbitmq_shovel,
    [{shovels, [
      {to_cega,
        [{source,
          [{protocol, amqp091},
            {uris, ["amqp://"]},
            {declarations, [{'queue.declare', [{exclusive, true}]},
              {'queue.bind',
                [{exchange, <<"cega">>},
                  {queue, <<>>},
                  {routing_key, <<"#">>}
                ]}
            ]},
            {queue, <<>>},
            {prefetch_count, 10}
          ]},
          {destination,
            [{protocol, amqp091},
              {uris, ["${CEGA_CONNECTION}"]},
              {declarations, []},
              {publish_properties, [{delivery_mode, 2}]},
              {publish_fields, [{exchange, <<"localega.v1">>}]}]},
          {ack_mode, on_confirm},
          {reconnect_delay, 5}
        ]},
      {cega_completion,
        [{source,
          [{protocol, amqp091},
            {uris, ["amqp://"]},
            {declarations, [{'queue.declare', [{exclusive, true}]},
              {'queue.bind',
                [{exchange, <<"lega">>},
                  {queue, <<>>},
                  {routing_key, <<"completed">>}
                ]}
            ]},
            {queue, <<>>},
            {prefetch_count, 10}
          ]},
          {destination,
            [{protocol, amqp091},
              {uris, ["amqp://"]},
              {declarations, []},
              {publish_properties, [{delivery_mode, 2}]},
              {publish_fields, [{exchange, <<"cega">>},
                {routing_key, <<"files.completed">>}
              ]}
            ]},
          {ack_mode, on_confirm},
          {reconnect_delay, 5}
        ]}
    ]}
    ]}
].
EOF
chown rabbitmq:rabbitmq /etc/rabbitmq/advanced.config
chmod 600 /etc/rabbitmq/advanced.config


exec "$@"
