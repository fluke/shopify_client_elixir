defmodule ShopifyClient.UndecodableBodyTest do
  use ShopifyClient.Case, async: true

  # Req guesses JSON from the `.json` URL when no content type is sent; an
  # undecodable body used to surface as a :transport error, losing the status.
  for {status, reason} <- [
        {502, :server_error},
        {503, :server_error},
        {401, :unauthorized},
        {404, :not_found}
      ] do
    test "a #{status} with a plain-text body keeps its status (#{inspect(reason)})" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, unquote(status), "bad gateway <html>"))

      assert {:error,
              %Error{
                reason: unquote(reason),
                status: unquote(status),
                details: "bad gateway <html>"
              }} =
               ShopifyClient.query(client(__MODULE__), "{ a }")
    end
  end
end
