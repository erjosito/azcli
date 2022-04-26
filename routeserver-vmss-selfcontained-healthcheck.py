import os
import socket, struct
import sys
import time
import warnings
import requests
from flask import Flask
from flask import request
from flask import jsonify

# Gets the web port out of an environment variable, or defaults to 8080
def get_web_port():
    web_port=os.environ.get('PORT')
    if web_port==None or not web_port.isnumeric():
        print("Using default port 8080")
        web_port=8080
    else:
        print("Port supplied as environment variable:", web_port)
    return web_port

app = Flask(__name__)

# Flask route for healthchecks
@app.route("/api/healthcheck", methods=['GET'])
def healthcheck():
    if request.method == 'GET':
        try:
          output_stream = os.popen('echo "birdc show protocols"')
          birdc_output = output_stream.read()
          msg = {
            'health': 'OK',
            'bird_status': birdc_output
          }          
          return jsonify(msg)
        except Exception as e:
          return jsonify(str(e))

# Ignore warnings
with warnings.catch_warnings():
    warnings.simplefilter("ignore")

# Set web port
web_port=get_web_port()

app.run(host='0.0.0.0', port=web_port, debug=True, use_reloader=False)
