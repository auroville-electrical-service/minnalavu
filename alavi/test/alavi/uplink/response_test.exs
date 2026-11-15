defmodule Alavi.Uplink.ResponseTest do
  use ExUnit.Case, async: true

  alias Alavi.Uplink.Response

  @batch "0f0e0d0c-0b0a-4908-8706-050403020100"
  @error ~s({"code":"PT422","message":"no"})

  describe "decide/2" do
    test "a 200 naming the batch is an acknowledgement, whatever the case of the id" do
      body = ~s({"batch_id":"#{String.upcase(@batch)}","readings":2})
      assert {:ack, %{"readings" => 2}} = Response.decide({:ok, 200, body}, @batch)
    end

    test "a 200 that does not name the batch is retried" do
      for body <- ["<html>login</html>", "{}", ~s({"batch_id":7}), ~s({"batch_id":"other"})] do
        assert {:retry, "HTTP 200 " <> _} = Response.decide({:ok, 200, body}, @batch), body
      end
    end

    test "400, 409 and 422 with a server error body are rejected for good" do
      for status <- [400, 409, 422] do
        assert {:quarantine, "HTTP #{status} PT422: no"} ==
                 Response.decide({:ok, status, @error}, @batch)
      end
    end

    test "400, 409 and 422 without a server error body are retried" do
      for status <- [400, 409, 422], body <- ["<html>proxy</html>", "{}", ~s({"code":7})] do
        assert {:retry, reason} = Response.decide({:ok, status, body}, @batch)
        assert reason =~ "HTTP #{status} without a server error body: "
      end
    end

    test "413 is rejected for good, with any body" do
      assert {:quarantine, "HTTP 413: too big"} == Response.decide({:ok, 413, "too big"}, @batch)
    end

    test "everything else is retried" do
      for status <- [401, 403, 404, 408, 429, 500, 503, 302] do
        assert {:retry, "HTTP #{status}: busy"} == Response.decide({:ok, status, "busy"}, @batch)
      end

      for reason <- [
            :econnrefused,
            :timeout,
            {:failed_connect, []},
            {:tls_alert, :bad_certificate}
          ] do
        assert {:retry, "no answer: " <> _} = Response.decide({:error, reason}, @batch)
      end
    end

    test "a body in a reason is cut to 300 characters, on one line, as valid UTF-8" do
      body = "a\n  b\xFF" <> String.duplicate("x", 400)
      assert {:retry, "HTTP 503: " <> shown} = Response.decide({:ok, 503, body}, @batch)
      assert String.length(shown) <= 300 and String.length(shown) > 290
      assert String.starts_with?(shown, "a b\uFFFDxx")
      assert String.valid?(shown)
      refute shown =~ "\n"
    end

    test "a server error message that is not text is shown as it is" do
      body = ~s({"code":"PT422","message":{"a":1}})

      assert {:quarantine, "HTTP 422 PT422: %{\"a\" => 1}"} ==
               Response.decide({:ok, 422, body}, @batch)
    end
  end

  describe "config/1" do
    test "a 200 with JSON is the document served, as decoded" do
      assert Response.config({:ok, 200, ~s({"schema_version": 1, "endpoints": []})}) ==
               {:ok, %{"schema_version" => 1, "endpoints" => []}}
    end

    test "anything else is a fetch that failed, with what came back" do
      assert {:error, "HTTP 200 without JSON: <html>" <> _} =
               Response.config({:ok, 200, "<html>login</html>"})

      assert {:error, "HTTP 403: " <> _} = Response.config({:ok, 403, @error})
      assert {:error, "no answer: " <> _} = Response.config({:error, :timeout})
    end
  end
end
