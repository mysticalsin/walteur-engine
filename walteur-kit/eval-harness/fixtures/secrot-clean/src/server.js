const express = require("express");
const AWS = require("aws-sdk");
const awsConfig = require("./config/aws");

AWS.config.update(awsConfig);

const app = express();
const s3 = new AWS.S3();

app.get("/healthz", (_req, res) => res.status(200).json({ status: "ok" }));

app.get("/exports/:batchId", async (req, res) => {
  try {
    const object = await s3
      .getObject({ Bucket: "billing-exports", Key: `${req.params.batchId}.csv` })
      .promise();
    res.status(200).send(object.Body);
  } catch (err) {
    res.status(502).json({ error: "export_fetch_failed" });
  }
});

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`billing-worker listening on ${port}`));
