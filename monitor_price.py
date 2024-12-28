# Este script monitorea el precio de cursos online en Udemy.
# Si el precio del curso es igual o menor a un monto definido por el usuario, dispara una notificación del sistema operativo

import time, requests, pytz
from bs4 import BeautifulSoup
from plyer import notification
from datetime import datetime

course_url = "https://www.udemy.com/course/ingenieria-inversa-y-cracking-de-software-preventivo/"
price_target = 20

buenos_aires_tz = pytz.timezone('America/Argentina/Buenos_Aires')
print("Monitoring... Use `Ctrl+C` to close the script")

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
            print("ERROR: Can't find the price.")
            price = None
            break

    except Exception as e:
        print("ERROR: Can't extract the price: ", str(e))
        price = None
        break

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
        else:
            time.sleep(60 * 60 * 1)  # Esperar 1 hora antes de volver a verificar cambios en el precio
    except:
        try:
            test = (price <= price_target)
            print(f"Bye bye! The last price was USD {price}")
            break
        except:
            print("ERROR: price format cause script crash")
            break
