# Este script monitorea el precio de cursos online en Udemy.
# Si el precio del curso es igual o menor a un monto definido por el usuario, dispara una notificación del sistema operativo

import time, requests
from bs4 import BeautifulSoup
from plyer import notification
from datetime import datetime

course_url = "https://www.udemy.com/course/ingenieria-inversa-y-cracking-de-software-preventivo/"
price_target = 20

from datetime import datetime
import pytz
buenos_aires_tz = pytz.timezone('America/Argentina/Buenos_Aires')

while True:
    try:
        response = requests.get(course_url)
        response.raise_for_status()

        soup = BeautifulSoup(response.text, 'html.parser')

        price_meta = soup.find('meta', {'property': 'udemy_com:price'})
        if price_meta:
            price = float(price_meta['content'][:5].replace(",","."))
            # print("Precio extraído:", price)
        else:
            print("ERROR: No se encontró el precio.")
            price = None

    except Exception as e:
        print("ERROR: No se logró extraer el precio:", str(e))
        price = None

    try:
        if price <= price_target:
            buenos_aires_time = datetime.now(buenos_aires_tz)
            message=f"The price of the course is on offer: {price}! {buenos_aires_time}"
            notification.notify(
                title="ALERT PRICE!",
                message=message,
                timeout=60*10  # Duración en segundos. Mantiene el cartel 10 minutos salvo que el usuario lo cierre manualmente
            )
            print(message) # Por las dudas también lo imprime por consola
            break
    except:
        pass
    time.sleep(60 * 60 * 1)  # Esperar 1 hora antes de volver a verificar cambios en el precio
