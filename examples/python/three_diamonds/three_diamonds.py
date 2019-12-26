import os
import requests
import googlemaps
from geopy.geocoders import Nominatim
from pyicloud import PyiCloudService


def get_icloud_device(cloud, device_id):
    if device_id in cloud.devices:
        return cloud.devices[device_id]
    else:
        return next(device for device in cloud.devices
                    if device_id.lower() in device.content['deviceDisplayName'].lower())

def get_icloud_coords(user, password, device_id):
    cloud = PyiCloudService(user, password)
    device = get_icloud_device(cloud, device_id)
    coords = device.location()
    return coords["latitude"], coords["longitude"]

def get_address(lat, lng):
    geo = Nominatim()
    location = geo.reverse((lat, lng))
    return location

def get_my_location_by_my_current_ip():
    resp = requests.get('http://freegeoip.net/json')
    data = resp.json()
    return data['latitude'], data['longitude']

def get_directions(key, origin_lat, origin_lng, dest_lat, dest_lng):
    gmaps = googlemaps.Client(key=key)
    directions = gmaps.directions((origin_lat, origin_lng), (dest_lat, dest_lng))
    return directions

if __name__ == '__main__':
    icloud_user = os.environ["ICLOUD_USER"]
    icloud_password = os.environ["ICLOUD_PASS"]
    icloud_deviceid = os.environ["ICLOUD_DEVICE"]
    gmaps_api_key = os.environ["GMAPS_API_KEY"]

    icloud_coords = get_icloud_coords(icloud_user, icloud_password, icloud_deviceid)
    icloud_addr = get_address(*icloud_coords)

    local_coords = get_my_location_by_my_current_ip()
    local_addr = get_address(*local_coords)

    directions = get_directions(gmaps_api_key, icloud_coords[0], icloud_coords[1], local_coords[0], local_coords[1])

    total_directions = directions[0]["legs"][0]

    print("Remote Coords: ", icloud_coords)
    print("Remote Addr: ", icloud_addr)
    print("Local Coords: ", local_coords)
    print("Local Addr: ", local_addr)
    print("Distance: ", total_directions["distance"], total_directions["duration"])
