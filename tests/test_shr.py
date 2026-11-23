#!/usr/bin/env python3
# coding: utf-8
from __future__ import division, print_function, unicode_literals

import json
import os
import shutil
import sqlite3
import tempfile
import unittest

from copyparty.__init__ import ANYWIN
from copyparty.authsrv import AuthSrv
from copyparty.httpcli import HttpCli
from copyparty.util import absreal
from tests import util as tu
from tests.util import Cfg


class TestShr(unittest.TestCase):
    def log(self, src, msg, c=0):
        m = "%s" % (msg,)
        if (
            "warning: filesystem-path does not exist:" in m
            or "you are sharing a system directory:" in m
            or "symlink-based deduplication is enabled" in m
            or m.startswith("hint: argument")
        ):
            return

        print(("[%s] %s" % (src, msg)).encode("ascii", "replace").decode("ascii"))

    def assertLD(self, url, auth, els, edl):
        ls = self.ls(url, auth)
        self.assertEqual(ls[0], len(els) == 2)
        if not ls[0]:
            return
        a = [list(sorted(els[0])), list(sorted(els[1]))]
        b = [list(sorted(ls[1])), list(sorted(ls[2]))]
        self.assertEqual(a, b)

        if edl is None:
            edl = els[1]
        can_dl = []
        zs = "f1 f2 f3 f4 l1 l2 l3 l4"
        known_fns = list(sorted(list(set(b[1] + zs.split()))))
        for fn in known_fns:
            if fn == "a.db":
                continue
            furl = url + "/" + fn
            if auth:
                furl += "?pw=p1"
            h, zb = self.curl(furl, True)
            if h.startswith("HTTP/1.1 200 "):
                can_dl.append(fn)
            elif zb.startswith(b">>fb:"):
                can_dl.append(fn)
        self.assertEqual(edl, list(sorted(list(set(can_dl)))))

    def setUp(self):
        self.td = tu.get_ramdisk()
        td = os.path.join(self.td, "vfs")
        os.mkdir(td)
        os.chdir(td)
        os.mkdir("d1")
        os.mkdir("d2")
        os.mkdir("d2/d3")
        os.mkdir("d2/d3/d4")
        for zs in ("d1/f1", "d2/f2", "d2/d3/f3", "d2/d3/d4/f4"):
            with open(zs, "wb") as f:
                f.write(b">>fb:" + zs.encode("utf-8"))
            for dst in ("d1", "d2", "d2/d3", "d2/d3/d4"):
                src, fn = zs.rsplit("/", 1)
                os.symlink(absreal(zs), dst + "/l" + fn[-1:])
        os.symlink(absreal("d2/d3"), absreal("d2/ld"))
        os.symlink(absreal("d2/d3"), absreal("d2/d3/d4/ld"))

        db = sqlite3.connect("a.db")
        with db:
            zs = r"create table sh (k text, pw text, vp text, pr text, st int, un text, t0 int, t1 int)"
            db.execute(zs)
            db.execute("create table sf (k text, vp text)")
        db.close()

    def tearDown(self):
        os.chdir(tempfile.gettempdir())
        shutil.rmtree(self.td)

    def cinit(self):
        self.asrv = AuthSrv(self.args, self.log)
        self.conn = tu.VHttpConn(self.args, self.asrv, self.log, b"", True)

    def test1(self):
        self.args = Cfg(
            a=["u1:p1"],
            v=["::A,u1", "d1:v1:A,u1", "d2/d3:d2/d3:A,u1"],
            shr="/shr/",
            shr1="shr/",
            shr_db="a.db",
            shr_v=False,
        )
        self.cinit()
        L1234 = ["l1", "l2", "l3", "l4"]

        self.assertLD("", True, [["d1", "d2", "v1"], ["a.db"]], [])
        self.assertLD("d1", True, [[], ["f1"] + L1234], None)
        self.assertLD("v1", True, [[], ["f1"] + L1234], None)
        self.assertLD("d2", True, [["d3", "ld"], ["f2"] + L1234], None)
        self.assertLD("d2/d3", True, [["d4"], ["f3"] + L1234], None)
        self.assertLD("d2/d3/d4", True, [["ld"], ["f4"] + L1234], None)
        self.assertLD("d3", True, [], [])

        jt = {
            "k": "r",
            "vp": ["/"],
            "pw": "",
            "exp": "99",
            "perms": ["read", "write"],
        }
        print(self.post_json("?pw=p1&share", jt)[1])
        jt = {
            "k": "d2",
            "vp": ["/d2/"],
            "pw": "",
            "exp": "99",
            "perms": ["read", "write"],
        }
        print(self.post_json("?pw=p1&share", jt)[1])
        jt = {
            "k": "d4",
            "vp": ["/d2/d3/d4/"],
            "pw": "",
            "exp": "99",
            "perms": ["read", "write"],
        }
        print(self.post_json("?pw=p1&share", jt)[1])
        self.conn.shutdown()
        self.cinit()

        self.assertLD("", True, [["d1", "d2", "v1"], ["a.db"]], [])
        self.assertLD("d1", True, [[], ["f1"] + L1234], None)
        self.assertLD("v1", True, [[], ["f1"] + L1234], None)
        self.assertLD("d2", True, [["d3", "ld"], ["f2"] + L1234], None)
        self.assertLD("d2/d3", True, [["d4"], ["f3"] + L1234], None)
        self.assertLD("d2/d3/d4", True, [["ld"], ["f4"] + L1234], None)
        self.assertLD("d3", True, [], [])

        self.assertLD("shr/d2", False, [["ld"], ["f2"] + L1234], None)
        self.assertLD("shr/d2/d3", False, [], None)
        self.assertLD("shr/d2/d3/d4", False, [], None)

        self.assertLD("shr/d4", False, [["ld"], ["f4"] + L1234], None)

        self.assertLD("shr/r", False, [["d1"], ["a.db"]], [])
        self.assertLD("shr/r/d1", False, [[], ["f1"] + L1234], None)
        self.assertLD("shr/r/d2", False, [], None)  # unfortunate
        self.assertLD("shr/r/d2/d3", False, [], None)
        self.assertLD("shr/r/d2/d3/d4", False, [], None)

        self.put("shr/d2/a", 201)
        os.unlink("d2/a")

        self.put("shr/d2/ld/a", 201)
        os.unlink("d2/d3/a")

        self.put("shr/d4/ld/a", 201)
        os.unlink("d2/d3/a")

        self.conn.shutdown()

    def test2(self):
        self.args = Cfg(
            a=["u1:p1"],
            v=["::A,u1", "d1:v1:A,u1", "d2/d3:d2/d3:A,u1"],
            shr="/shr/",
            shr1="shr/",
            shr_db="a.db",
            shr_v=False,
            xvol=True,
        )
        self.cinit()
        L1234 = ["l1", "l2", "l3", "l4"]

        self.assertLD("", True, [["d1", "d2", "v1"], ["a.db"]], [])
        self.assertLD("d1", True, [[], ["f1"] + L1234], None)
        self.assertLD("v1", True, [[], ["f1"] + L1234], None)
        self.assertLD("d2", True, [["d3", "ld"], ["f2"] + L1234], None)
        self.assertLD("d2/d3", True, [["d4"], ["f3"] + L1234], None)
        self.assertLD("d2/d3/d4", True, [["ld"], ["f4"] + L1234], None)
        self.assertLD("d3", True, [], [])

        jt = {
            "k": "r",
            "vp": ["/"],
            "pw": "",
            "exp": "99",
            "perms": ["read", "write"],
        }
        print(self.post_json("?pw=p1&share", jt)[1])
        jt = {
            "k": "d2",
            "vp": ["/d2/"],
            "pw": "",
            "exp": "99",
            "perms": ["read", "write"],
        }
        print(self.post_json("?pw=p1&share", jt)[1])
        jt = {
            "k": "d4",
            "vp": ["/d2/d3/d4/"],
            "pw": "",
            "exp": "99",
            "perms": ["read", "write"],
        }
        print(self.post_json("?pw=p1&share", jt)[1])
        self.conn.shutdown()
        self.cinit()

        self.assertLD("", True, [["d1", "d2", "v1"], ["a.db"]], [])
        self.assertLD("d1", True, [[], ["f1"] + L1234], None)
        self.assertLD("v1", True, [[], ["f1"] + L1234], None)
        self.assertLD("d2", True, [["d3", "ld"], ["f2"] + L1234], None)
        self.assertLD("d2/d3", True, [["d4"], ["f3"] + L1234], None)
        self.assertLD("d2/d3/d4", True, [["ld"], ["f4"] + L1234], None)
        self.assertLD("d3", True, [], [])

        self.assertLD("shr/d2", False, [["ld"], ["f2"] + L1234], ["f2", "l2"])
        self.assertLD("shr/d2/d3", False, [], [])
        self.assertLD("shr/d2/d3/d4", False, [], None)

        self.assertLD("shr/d4", False, [["ld"], ["f4"] + L1234], ["f4", "l4"])

        self.assertLD("shr/r", False, [["d1"], ["a.db"]], [])
        self.assertLD("shr/r/d1", False, [[], ["f1"] + L1234], ["f1", "l1", "l2"])
        self.assertLD("shr/r/d2", False, [], [])  # unfortunate
        self.assertLD("shr/r/d2/d3", False, [], [])
        self.assertLD("shr/r/d2/d3/d4", False, [], None)

        self.put("shr/d2/a", 201)
        os.unlink("d2/a")

        self.put("shr/d2/ld/a", 401)
        self.put("shr/d4/ld/a", 401)

        self.conn.shutdown()

    def test_public_paths(self):
        self.args = Cfg(
            a=["u1:p1", "u2:p4"],
            v=["::A,u1:r,u2"],
            shr="/shr/",
            shr1="shr/",
            shr_db="a.db",
            shr_path=True,
            shr_site="https://share.example.com/",
            shr_adm="",
            shr_rt=1440,
            shr_v=False,
            xvol=True,
        )
        self.args.shr_who = "a"
        self.cinit()
        self.addCleanup(self.conn.shutdown)
        self.assertEqual(self.ls("shr", False), (True, [], []))
        with open("d1/f1b", "wb") as f:
            f.write(b"second file")

        file_req = {"vp": ["/d1/f1"], "exp": "0", "perms": ["read"]}
        auth = "?pw=p1&share"
        h, body = self.post_json(auth, dict(file_req, path="python/aaa.py"))
        self.assertTrue(h.startswith("HTTP/1.1 201 "), body)
        self.assertIn("created share: https://share.example.com/shr/python/aaa.py", body)
        h, body = self.post_json(auth, dict(file_req, path="python/also here +.py"))
        self.assertTrue(h.startswith("HTTP/1.1 201 "), body)
        self.assertIn("/shr/python/also%20here%20%2B.py", body)
        h, body = self.post_json(auth, dict(file_req, k="secret", pw="p2"))
        self.assertTrue(h.startswith("HTTP/1.1 201 "), body)
        self.assertIn("/shr/secret/f1", body)
        h, body = self.post_json(auth, dict(file_req, k="unlisted"))
        self.assertTrue(h.startswith("HTTP/1.1 201 "), body)
        h, body = self.post_json(auth, dict(file_req, path="libraries/one", vp=["/d1/"]))
        self.assertTrue(h.startswith("HTTP/1.1 201 "), body)
        h, body = self.post_json(
            auth, dict(file_req, path="libraries/pair", vp=["/d1/f1", "/d1/f1b"])
        )
        self.assertTrue(h.startswith("HTTP/1.1 201 "), body)

        for path in (
            "python", "python/aaa.py", "python/aaa.py/x", "secret/x",
            "a/../b", "a//b", "/a", "a/", "",
        ):
            h, body = self.post_json(auth, dict(file_req, path=path))
            self.assertTrue(h.startswith("HTTP/1.1 400 "), body)
        h, body = self.post_json(auth, dict(file_req, k="python"))
        self.assertTrue(h.startswith("HTTP/1.1 400 "), body)
        h, body = self.post_json(auth, dict(file_req, path="private", pw="p3"))
        self.assertTrue(h.startswith("HTTP/1.1 400 "), body)
        h, body = self.post_json("?share", dict(file_req, path="unauthorized"))
        self.assertTrue(h.startswith("HTTP/1.1 400 "), body)
        h, body = self.post_json("?pw=p4&share", dict(file_req, path="non-admin"))
        self.assertTrue(h.startswith("HTTP/1.1 400 "), body)

        self.asrv.reload()
        self.assertEqual(self.ls("shr", False), (True, ["libraries", "python"], []))
        self.assertEqual(
            self.ls("shr/python", False), (True, [], ["aaa.py", "also%20here%20%2B.py"])
        )
        self.assertEqual(self.ls("shr/libraries/pair", False), (True, [], ["f1", "f1b"]))
        self.assertIn("f1", self.ls("shr/libraries/one", False)[2])
        _, body = self.curl("shr?pw=p2&ls")
        self.assertEqual(
            [x["href"] for x in json.loads(body)["dirs"]], ["libraries/", "python/"]
        )
        for path in (
            "python/aaa.py", "python/also%20here%20%2B.py", "secret/f1?pw=p2", "unlisted/f1",
        ):
            h, body = self.curl("shr/" + path, True)
            self.assertTrue(h.startswith("HTTP/1.1 200 "), h)
            self.assertEqual(body, b">>fb:d1/f1")
        for path in ("shr/python/f1", "shr/python/aaa.py/f1", "shr/secret/f1", "d1/f1"):
            h, _ = self.curl(path)
            self.assertFalse(h.startswith("HTTP/1.1 200 "), h)

        with sqlite3.connect("a.db") as db:
            db.execute("update sh set t1 = 2 where k = ?", ("/python/aaa.py",))
        self.asrv.reload()
        self.assertEqual(self.ls("shr/python", False), (True, [], ["also%20here%20%2B.py"]))

        req = (
            b"POST /?pw=p1&eshare=rm&skey=%2Fpython%2Falso%20here%20%2B.py HTTP/1.1\r\n"
            b"Connection: close\r\n\r\n"
        )
        HttpCli(self.conn.setbuf(req)).run()
        self.assertTrue(self.conn.s._reply.startswith(b"HTTP/1.1 200 "))
        self.asrv.reload()
        self.assertEqual(self.ls("shr", False), (True, ["libraries"], []))

        self.args.shr_path = False
        self.asrv.reload()
        self.assertFalse(self.ls("shr/libraries/pair", False)[0])
        self.assertTrue(self.curl("shr/secret/f1?pw=p2")[0].startswith("HTTP/1.1 200 "))

    def ls(self, url: str, auth: bool):
        zs = url + "?ls" + ("&pw=p1" if auth else "")
        h, b = self.curl(zs)
        if not h.startswith("HTTP/1.1 200 "):
            return (False, [], [])
        jo = json.loads(b)
        return (
            True,
            [x["href"].rstrip("/") for x in jo.get("dirs") or {}],
            [x["href"] for x in jo.get("files") or {}],
        )

    def curl(self, url: str, binary=False):
        h = "GET /%s HTTP/1.1\r\nConnection: close\r\n\r\n"
        HttpCli(self.conn.setbuf((h % (url,)).encode("utf-8"))).run()
        if binary:
            h, b = self.conn.s._reply.split(b"\r\n\r\n", 1)
            return [h.decode("utf-8"), b]

        return self.conn.s._reply.decode("utf-8").split("\r\n\r\n", 1)

    def post_json(self, url: str, data):
        buf = json.dumps(data).encode("utf-8")
        msg = [
            "POST /%s HTTP/1.1" % (url,),
            "Connection: close",
            "Content-Type: application/json",
            "Content-Length: %d" % (len(buf),),
            "\r\n",
        ]
        buf = "\r\n".join(msg).encode("utf-8") + buf
        print("PUT -->", buf)
        HttpCli(self.conn.setbuf(buf)).run()
        return self.conn.s._reply.decode("utf-8").split("\r\n\r\n", 1)

    def put(self, url: str, expect: str):
        h = "PUT /%s HTTP/1.1\r\nContent-Length: 1\r\n\r\n`"
        HttpCli(self.conn.setbuf((h % (url,)).encode("utf-8"))).run()
        h, r = self.conn.s._reply.decode("utf-8").split("\r\n\r\n", 1)
        self.assertEqual(expect, int(h.split(" ")[1]))
