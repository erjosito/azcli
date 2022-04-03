import os
import socket, struct
import sys
import time
import warnings
import requests
from flask import Flask
from flask import request
from flask import jsonify

# Return True if IP address is valid
def is_valid_ipv4_address(address):
    try:
        socket.inet_pton(socket.AF_INET, address)
    except AttributeError:  # no inet_pton here, sorry
        try:
            socket.inet_aton(address)
        except socket.error:
            return False
        return address.count('.') == 3
    except socket.error:  # not a valid address
        return False
    return True

# Get IP for a DNS name
def get_ip(d):
    try:
        return socket.gethostbyname(d)
    except Exception:
        return False

app = Flask(__name__)

# Get IP addresses of DNS servers
def get_dns_ips():
    dns_ips = []
    with open('/etc/resolv.conf') as fp:
        for cnt, line in enumerate(fp):
            columns = line.split()
            if columns[0] == 'nameserver':
                ip = columns[1:][0]
                if is_valid_ipv4_address(ip):
                    dns_ips.append(ip)
    return dns_ips

# Get default gateway
def get_default_gateway():
    """Read the default gateway directly from /proc."""
    with open("/proc/net/route") as fh:
        for line in fh:
            fields = line.strip().split()
            if fields[1] != '00000000' or not int(fields[3], 16) & 2:
                continue

            return socket.inet_ntoa(struct.pack("<L", int(fields[2], 16)))

# Flask route to print all HTTP headers
@app.route("/api/headers", methods=['GET'])
def headers():
    if request.method == 'GET':
        try:
            return jsonify(dict(request.headers))
        except Exception as e:
            return jsonify(str(e))
        
# Flask route for healthchecks
@app.route("/api/healthcheck", methods=['GET'])
def healthcheck():
    if request.method == 'GET':
        try:
          msg = {
            'health': 'OK'
          }          
          return jsonify(msg)
        except Exception as e:
          return jsonify(str(e))

# Route to uplode file and return file size
@app.route('/api/filesize', methods=['POST'])
def getsize():
    try:
      uploaded_file = request.files['data']
      if uploaded_file:
          f = uploaded_file.read()
          msg = {
             'size': len(f)
          }
      else:
         msg = {
             'size': 'unknown'
         }
      return jsonify(msg)
    except Exception as e:
        return jsonify(str(e))

# Flask route to provide the container's IP address
@app.route("/api/dns", methods=['GET'])
def dns():
    try:
        fqdn = request.args.get('fqdn')
        ip = get_ip(fqdn)
        msg = {
                'fqdn': fqdn,
                'ip': ip
        }          
        return jsonify(msg)
    except Exception as e:
        return jsonify(str(e))
        

# Flask route to provide the container's IP address
@app.route("/api/ip", methods=['GET'])
def ip():
    if request.method == 'GET':
        try:
            app.logger.info('Getting public IP address...')     # DEBUG
            # url = 'http://ifconfig.co/json'
            url = 'http://jsonip.com'
            mypip_json = requests.get(url).json()
            try:
                mypip = mypip_json['ip']
            except:
                mypip = "Could not extract public IP from JSON: " + str(mypip_json)
            app.logger.info('Getting X-Forwarded-For header...')        # DEBUG
            if request.headers.getlist("X-Forwarded-For"):
                try:
                    forwarded_for = request.headers.getlist("X-Forwarded-For")[0]
                except:
                    forwarded_for = None
            else:
                forwarded_for = None
            # app.logger.info('Getting your IP address...')               # DEBUG
            try:
                your_address = str(request.environ.get('REMOTE_ADDR', ''))
            except:
                your_address = ""
            # app.logger.info('Getting your DNS servers...')              # DEBUG
            try:
                dns_servers = str(get_dns_ips())
            except:
                dns_servers = ""
            # app.logger.info('Getting your default gateway...')          # DEBUG
            try:
                default_gateway = str(get_default_gateway())
            except:
                default_gateway = ""
            # app.logger.info('Getting path accessed...')                 # DEBUG
            try:
                path_accessed = str(request.environ['HTTP_HOST']) + str(request.environ['PATH_INFO'])
            except:
                path_accessed = ""
            msg = {
                'my_private_ip': get_ip(socket.gethostname()),
                'my_public_ip': mypip,
                'my_dns_servers': dns_servers,
                'my_default_gateway': default_gateway,
                'your_address': your_address,
                'x-forwarded-for': forwarded_for,
                'path_accessed': path_accessed,
                'your_platform': str(request.user_agent.platform),
                'your_browser': str(request.user_agent.browser),
            }          
            return jsonify(msg)
        except Exception as e:
            return jsonify(str(e))

# Flask route to provide the container's environment variables
@app.route("/api/printenv", methods=['GET'])
def printenv():
    if request.method == 'GET':
        try:
            return jsonify(dict(os.environ))
        except Exception as e:
            return jsonify(str(e))

# Flask route to run a HTTP GET to a target URL and return the answer
@app.route("/api/curl", methods=['GET'])
def curl():
    if request.method == 'GET':
        try:
            url = request.args.get('url')
            if url == None:
                url='http://jsonip.com'
            http_answer = requests.get(url).text
            msg = {
                'url': url,
                'method': 'GET',
                'answer': http_answer
            }          
            return jsonify(msg)
        except Exception as e:
            return jsonify(str(e))

# Gets the web port out of an environment variable, or defaults to 8080
def get_web_port():
    web_port=os.environ.get('PORT')
    if web_port==None or not web_port.isnumeric():
        print("Using default port 8080")
        web_port=8080
    else:
        print("Port supplied as environment variable:", web_port)
    return web_port

# Ignore warnings
with warnings.catch_warnings():
    warnings.simplefilter("ignore")

# Set web port
web_port=get_web_port()

app.run(host='0.0.0.0', port=web_port, debug=True, use_reloader=False)
