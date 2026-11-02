"""Dane demonstracyjne (DEMO=1) - pozwalają zobaczyć działającą aplikację przed skonfigurowaniem źródeł."""
from datetime import datetime, timedelta, timezone

from .geo import Powiaty
from .models import Claim, RawItem
from .sources import IMGW_SEVERITY


def demo_items(now: datetime | None = None, powiaty: Powiaty | None = None):
    now = now or datetime.now(timezone.utc)
    m = lambda x: now - timedelta(minutes=x)  # noqa: E731
    I = RawItem  # noqa: E741
    items = [
        # blackout wyłącznie z mało wiarygodnych źródeł, operator milczy -> podejrzane
        I("tg_a", "Kanał TG A", "social", "https://example.invalid/1",
          "W Przasnyszu nigdzie nie ma prądu! Mówią, że to sabotaż, całe miasto bez zasilania", m(120)),
        I("agg_x", "Mapa-agregator", "aggregator", "https://example.invalid/2",
          "W Przasnyszu nigdzie nie ma prądu! Mówią, że to sabotaż, całe miasto bez zasilania", m(118)),
        I("tg_b", "Kanał TG B", "social", "https://example.invalid/3",
          "W Przasnyszu nigdzie nie ma prądu! Mówią, że to sabotaż, całe miasto bez zasilania", m(115)),
        # zwykła awaria wody potwierdzona przez wodociągi i portal
        I("wod_dzial", "Wodociągi Działdowo", "official", "https://example.invalid/4",
          "Awaria sieci wodociągowej w Działdowie, brak wody w części miasta", m(90)),
        I("portal_dz", "Portal lokalny", "media_local", "https://example.invalid/5",
          "Mieszkańcy Działdowa zgłaszają brak wody, trwa awaria", m(80)),
        # prawdziwa awaria prądu potwierdzona przez operatora
        I("energa_demo", "Energa Operator", "official", "https://example.invalid/6",
          "Ostrołęka wyłączenie awaryjne brak prądu ulice centrum", m(50)),
        I("portal_os", "Portal lokalny", "media_local", "https://example.invalid/7",
          "W Ostrołęce nie ma prądu w centrum", m(45)),
        # niepokoje z jednego źródła lokalnego
        I("portal_ol", "Portal lokalny", "media_local", "https://example.invalid/8",
          "W Olsztynie pokojowe demonstracje przerodziły się w zamieszki", m(30)),
        # pożar lasu i awaria ogólnokrajowa z mediów
        I("pap_demo", "PAP", "media_national", "https://example.invalid/9",
          "Pożar lasu pod Łomżą, trwa ewakuacja pobliskich zabudowań", m(40)),
        I("tvn_demo", "TVN24", "media_national", "https://example.invalid/10",
          "Awaria mObywatela w całej Polsce, urzędy nie mogą obsługiwać klientów", m(25)),
    ]
    claims = []
    if powiaty:   # ostrzeżenia IMGW dla powiatów (jak z prawdziwego API)
        for code, name, level in (("1402", "Silny wiatr", 2), ("2814", "Mróz", 1), ("1413", "Burze z gradem", 3)):
            p = powiaty.get(code)
            it = I("imgw_meteo", "IMGW-PIB ostrzeżenia meteo", "official", "https://meteo.imgw.pl/", name, now)
            claims.append(Claim(it, p, "weather", IMGW_SEVERITY[level], label=f"{name}, stopień {level}",
                                key=f"imgw:{code}:{name}", valid_to=now + timedelta(hours=14)))
    return items, claims, {"power": True}
