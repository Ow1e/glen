import glen/glen
import glen/types, glen/db as glendb, glen/txn
import std/os

let dir = getCurrentDir() / "exampledb"
let database = newGlenDB(dir)

let h = database.subscribe("users", "u1", proc(id: Id; v: Value) =
  echo "Subscription update for ", $id, ": ", $v
)

database.put("users", "u1", VObject())

var userVal = VObject()
userVal["name"] = VString("Alice")
userVal["age"] = VInt(30)
database.put("users", "u2", userVal)

# Committed transaction example
let t2 = database.beginTxn()
var newUser = VObject()
newUser["name"] = VString("Bob")
newUser["age"] = VInt(25)
t2.stagePut(Id(collection: "users", docId: "u3", version: 0'u64), newUser)
let res = database.commit(t2)
echo "Txn commit status: ", $res.status

database.snapshotAll()

echo "Get users/u2 -> ", database.get("users", "u2")
echo "Get users/u3 -> ", database.get("users", "u3")
database.unsubscribe(h)
