O=../../cortex/om; sh cc.sh srv stubj.om $O/crc32c.om stubf.om $O/http.om $O/store.om $O/log.om $O/api.om $O/api2.om $O/api3.om $O/qs.om $O/enc.om stubd.om $O/main.om 2>&1 | head -c 400
